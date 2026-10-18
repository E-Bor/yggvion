package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"yggvion/server/internal/httpapi"
	"yggvion/server/internal/store"
)

func env(key, fallback string) string {
	if s := os.Getenv(key); s != "" {
		return s
	}
	return fallback
}
func main() {
	key := os.Getenv("YGGVION_PAIRING_KEY")
	if len(key) < 32 {
		slog.Error("YGGVION_PAIRING_KEY must contain at least 32 characters")
		os.Exit(1)
	}
	dir := env("YGGVION_DATA_DIR", "data")
	s, e := store.Open(filepath.Join(dir, "yggvion.db"))
	if e != nil {
		slog.Error("open database", "error", e)
		os.Exit(1)
	}
	defer s.Close()
	api := httpapi.New(s, key, filepath.Join(dir, "attachments"))
	server := &http.Server{Addr: env("YGGVION_LISTEN", "127.0.0.1:8080"), Handler: api.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 120 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16 << 10}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if e := server.Shutdown(shutdown); e != nil {
			slog.Error("shutdown", "error", e)
		}
	}()
	slog.Info("server listening", "address", server.Addr)
	if e := server.ListenAndServe(); e != nil && e != http.ErrServerClosed {
		slog.Error("serve", "error", e)
		os.Exit(1)
	}
}
