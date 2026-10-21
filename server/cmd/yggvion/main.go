package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"yggvion/server/internal/backup"
	"yggvion/server/internal/httpapi"
	"yggvion/server/internal/identity"
	"yggvion/server/internal/store"
)

func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
func main() {
	if len(os.Args) > 1 && (os.Args[1] == "migrate" || os.Args[1] == "snapshot-db") {
		dir := env("YGGVION_DATA_DIR", "data")
		var err error
		if os.Args[1] == "snapshot-db" {
			if len(os.Args) != 3 {
				slog.Error("snapshot-db requires destination")
				os.Exit(1)
			}
			err = store.SnapshotDatabase(filepath.Join(dir, "yggvion.db"), os.Args[2])
		} else {
			var db *store.Store
			db, err = store.Open(filepath.Join(dir, "yggvion.db"))
			if err == nil {
				err = db.Close()
			}
		}
		if err != nil {
			slog.Error("database maintenance", "error", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "backup" {
		dir := env("YGGVION_DATA_DIR", "data")
		s, err := store.Open(filepath.Join(dir, "yggvion.db"))
		if err != nil {
			slog.Error("open database", "error", err)
			os.Exit(1)
		}
		defer s.Close()
		m, err := backup.Open(s, filepath.Join(dir, "backups"), filepath.Join(dir, "attachments"), &sync.RWMutex{})
		if err == nil {
			_, err = m.Create(context.Background(), "before_update")
		}
		if err != nil {
			slog.Error("pre-update backup failed", "error", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "bootstrap" {
		if err := bootstrap(os.Args[2:]); err != nil {
			slog.Error("bootstrap failed", "error", err)
			os.Exit(1)
		}
		return
	}
	key := os.Getenv("YGGVION_PAIRING_KEY")
	dir := env("YGGVION_DATA_DIR", "data")
	var config struct {
		Host string `json:"host"`
		Port int    `json:"port"`
	}
	if data, err := os.ReadFile(filepath.Join(dir, "server.json")); err == nil {
		if err = json.Unmarshal(data, &config); err != nil || config.Host == "" || config.Port < 1 || config.Port > 65535 {
			slog.Error("invalid server.json")
			os.Exit(1)
		}
	} else if !os.IsNotExist(err) {
		slog.Error("read server configuration", "error", err)
		os.Exit(1)
	}
	if config.Host == "" && len(key) < 32 {
		slog.Error("YGGVION_PAIRING_KEY must contain at least 32 characters")
		os.Exit(1)
	}
	s, e := store.Open(filepath.Join(dir, "yggvion.db"))
	if e != nil {
		slog.Error("open database", "error", e)
		os.Exit(1)
	}
	defer s.Close()
	api := httpapi.New(s, key, filepath.Join(dir, "attachments"))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	api.Lifetime = ctx
	api.Backups, e = backup.Open(s, filepath.Join(dir, "backups"), api.Files, &api.DataMu)
	if e != nil {
		slog.Error("open backups", "error", e)
		os.Exit(1)
	}
	go api.Backups.Run(ctx)
	addr := env("YGGVION_LISTEN", "127.0.0.1:8080")
	var tlsManager *identity.Manager
	if config.Host != "" {
		tlsManager, e = identity.Open(filepath.Join(dir, "identity"), config.Host, time.Now())
		if e != nil {
			slog.Error("open TLS identity", "error", e)
			os.Exit(1)
		}
		api.CAPEM = string(tlsManager.CAPEM)
		addr = fmt.Sprintf(":%d", config.Port)
		go tlsManager.Run(ctx)
	}
	server := &http.Server{Addr: addr, Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 120 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16 << 10}
	if tlsManager != nil {
		server.TLSConfig = tlsManager.Config()
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if e := server.Shutdown(shutdown); e != nil {
			slog.Error("shutdown", "error", e)
		}
	}()
	slog.Info("server listening", "address", server.Addr)
	if tlsManager != nil {
		e = server.ListenAndServeTLS("", "")
	} else {
		e = server.ListenAndServe()
	}
	if e != nil && e != http.ErrServerClosed {
		slog.Error("serve", "error", e)
		os.Exit(1)
	}
}

func bootstrap(args []string) error {
	flags := flag.NewFlagSet("bootstrap", flag.ContinueOnError)
	dir := flags.String("data-dir", "/var/lib/yggvion", "Server data directory")
	host := flags.String("host", "", "Public IP address")
	port := flags.Int("port", 443, "HTTPS port")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *port < 1 || *port > 65535 {
		return fmt.Errorf("invalid port")
	}
	manager, err := identity.Open(filepath.Join(*dir, "identity"), *host, time.Now())
	if err != nil {
		return err
	}
	s, err := store.Open(filepath.Join(*dir, "yggvion.db"))
	if err != nil {
		return err
	}
	defer s.Close()
	code, err := s.Invite(context.Background(), "bootstrap")
	if err != nil {
		return err
	}
	config, err := json.Marshal(map[string]any{"host": *host, "port": *port})
	if err != nil {
		return err
	}
	path := filepath.Join(*dir, "server.json")
	if existing, e := os.ReadFile(path); e == nil && string(existing) != string(config) {
		return fmt.Errorf("existing server address differs; refusing implicit reconfiguration")
	} else if e != nil && !os.IsNotExist(e) {
		return e
	}
	if err = os.WriteFile(path, config, 0600); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{"code": code, "private_ca": string(manager.CAPEM), "port": *port})
}
