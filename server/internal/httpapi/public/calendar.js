"use strict";
(() => {
  const $ = (id) => document.getElementById(id);
  const token = location.hash.slice(1);
  let data,
    first,
    selection,
    nonce,
    sending = false,
    expired = false;
  let columns = matchMedia("(max-width:760px)").matches ? 1 : 7;
  const minuteHeight = 56 / 60;
  const dayStart = (value) => {
    const date = new Date(value);
    date.setHours(0, 0, 0, 0);
    return date;
  };
  const addDays = (value, amount) => {
    const date = new Date(value);
    date.setDate(date.getDate() + amount);
    return date;
  };
  const atMinute = (day, minute) => {
    const date = new Date(day);
    date.setHours(0, minute, 0, 0);
    return date;
  };
  const time = (value) =>
    new Date(value).toLocaleTimeString("ru-RU", {
      hour: "2-digit",
      minute: "2-digit",
    });
  const dateLabel = (value) =>
    new Date(value).toLocaleDateString("ru-RU", {
      day: "numeric",
      month: "long",
    });
  const inputTime = (value) =>
    `${String(value.getHours()).padStart(2, "0")}:${String(value.getMinutes()).padStart(2, "0")}`;
  const node = (tag, cls, text) => {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== undefined) el.textContent = text;
    return el;
  };
  const serverNow = () => new Date(Date.now() + (data?.clockOffset || 0));
  function unavailable(
    message = "Срок приглашения закончился. Попросите владельца прислать новую ссылку.",
  ) {
    expired = true;
    $("notice").textContent = message;
    $("workspace").hidden = true;
    $("timeline").replaceChildren();
    $("expiry").textContent = "Приглашение недоступно";
  }
  async function request(path, body) {
    const response = await fetch(path, {
      method: body ? "POST" : "GET",
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      headers: {
        Authorization: `Bearer ${token}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (response.status === 404) {
      unavailable();
      throw Error("Ссылка недоступна");
    }
    if (response.status === 429)
      throw Error("Слишком много запросов или предложений. Попробуйте позже.");
    if (response.status === 409)
      throw Error("Это время уже занято. Выберите другой интервал.");
    if (!response.ok)
      throw Error(
        "Не удалось отправить запрос. Проверьте время и попробуйте ещё раз.",
      );
    return response.json();
  }
  function valid(range) {
    return (
      range &&
      range.end > range.start &&
      range.end - range.start <= 86400000 &&
      range.start >= serverNow() &&
      range.start >= new Date(data.start) &&
      range.end <= new Date(data.end) &&
      !data.busy.some(
        (b) => range.start < new Date(b.end) && range.end > new Date(b.start),
      )
    );
  }
  function select(start, end) {
    selection = { start, end };
    nonce = crypto.randomUUID();
    $("selection-title").textContent = "Предложить встречу";
    $("selection-help").hidden = true;
    $("success").hidden = true;
    $("form").hidden = false;
    $("selected-time").textContent =
      `${dateLabel(start)} · ${time(start)} — ${+dayStart(start) === +dayStart(end) ? "" : dateLabel(end) + " · "}${time(end)}`;
    $("start-time").value = inputTime(start);
    $("end-time").value = inputTime(end);
    $("form-error").textContent = valid(selection)
      ? ""
      : "Выберите свободное время в будущем в пределах приглашения.";
    $("submit").disabled = !valid(selection) || sending || expired;
    drawSelection();
  }
  function paintBlock(column, start, end, cls, text) {
    const day = new Date(Number(column.dataset.day)),
      limit = addDays(day, 1);
    const a = new Date(Math.max(+start, +day)),
      b = new Date(Math.min(+end, +limit));
    if (b <= a) return;
    // The grid is a civil clock (24 rows), including daylight-saving days.
    const from = a.getHours() * 60 + a.getMinutes(),
      to = +b === +limit ? 1440 : b.getHours() * 60 + b.getMinutes();
    const block = node("div", cls, text);
    block.style.top = `${from * minuteHeight}px`;
    block.style.height = `${Math.max(7, (to - from) * minuteHeight)}px`;
    column.append(block);
  }
  function drawSelection() {
    document.querySelectorAll(".selection").forEach((el) => el.remove());
    if (!selection) return;
    document
      .querySelectorAll(".day-column")
      .forEach((column) =>
        paintBlock(
          column,
          selection.start,
          selection.end,
          "selection",
          `${time(selection.start)}–${time(selection.end)}`,
        ),
      );
  }
  function render() {
    const heads = $("days"),
      timeline = $("timeline");
    heads.replaceChildren(node("div"));
    timeline.replaceChildren();
    $("grid").style.setProperty("--columns", columns);
    $("range").textContent =
      columns === 1
        ? dateLabel(first)
        : `${dateLabel(first)} — ${dateLabel(addDays(first, columns - 1))}`;
    $("prev").disabled = first <= dayStart(data.start);
    $("next").disabled = addDays(first, columns) >= new Date(data.end);
    const ruler = node("div", "ruler");
    for (let hour = 1; hour < 24; hour++) {
      const label = node(
        "span",
        "hour-label",
        `${String(hour).padStart(2, "0")}:00`,
      );
      label.style.top = `${hour * 56}px`;
      ruler.append(label);
    }
    timeline.append(ruler);
    for (let i = 0; i < columns; i++) {
      const day = addDays(first, i),
        head = node(
          "div",
          "day-head" + (+day === +dayStart(new Date()) ? " current" : ""),
          day.toLocaleDateString("ru-RU", { weekday: "short" }),
        );
      head.append(node("b", "", day.getDate()));
      heads.append(head);
      const column = node("div", "day-column");
      column.dataset.day = +day;
      column.tabIndex = 0;
      column.setAttribute(
        "aria-label",
        `${dateLabel(day)}. Enter — предложить время, стрелки — изменить начало.`,
      );
      for (const busy of data.busy)
        paintBlock(
          column,
          new Date(busy.start),
          new Date(busy.end),
          "busy-block",
          "Занято",
        );
      let anchor,
        active = false,
        wait,
        originY,
        keyboardMinute = 12 * 60;
      const slot = (event) =>
        Math.max(
          0,
          Math.min(
            1425,
            Math.floor(
              (event.clientY - column.getBoundingClientRect().top) /
                minuteHeight /
                15,
            ) * 15,
          ),
        );
      column.addEventListener("pointerdown", (event) => {
        if (sending || expired || event.button !== 0) return;
        originY = event.clientY;
        anchor = slot(event);
        const begin = () => {
          active = true;
          column.setPointerCapture(event.pointerId);
          select(atMinute(day, anchor), atMinute(day, anchor + 30));
          if (
            event.pointerType === "touch" &&
            navigator.userActivation?.hasBeenActive
          )
            navigator.vibrate?.(15);
        };
        if (event.pointerType === "touch") wait = setTimeout(begin, 350);
        else begin();
      });
      column.addEventListener("pointermove", (event) => {
        if (!active) {
          if (Math.abs(event.clientY - originY) > 10) clearTimeout(wait);
          return;
        }
        const minute = slot(event);
        select(
          atMinute(day, Math.min(anchor, minute)),
          atMinute(day, Math.max(anchor + 15, minute + 15)),
        );
        const rect = $("viewport").getBoundingClientRect();
        if (event.clientY > rect.bottom - 50) $("viewport").scrollTop += 12;
        else if (event.clientY < rect.top + 90) $("viewport").scrollTop -= 12;
      });
      column.addEventListener(
        "touchmove",
        (event) => {
          if (active) event.preventDefault();
        },
        { passive: false },
      );
      column.addEventListener("pointerup", (event) => {
        clearTimeout(wait);
        const tap =
          event.pointerType === "touch" &&
          Math.abs(event.clientY - originY) < 10;
        if (!active && tap)
          select(atMinute(day, anchor), atMinute(day, anchor + 30));
        if (columns === 1 && (active || tap) && selection)
          $("proposal-panel").scrollIntoView({
            behavior: "smooth",
            block: "start",
          });
        active = false;
      });
      column.addEventListener("pointercancel", () => {
        clearTimeout(wait);
        active = false;
      });
      column.addEventListener("keydown", (event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          keyboardMinute = Math.max(
            0,
            Math.min(
              1410,
              keyboardMinute + (event.key === "ArrowDown" ? 15 : -15),
            ),
          );
          select(
            atMinute(day, keyboardMinute),
            atMinute(day, keyboardMinute + 30),
          );
        } else if (event.key === "Enter") {
          event.preventDefault();
          select(
            atMinute(day, keyboardMinute),
            atMinute(day, keyboardMinute + 30),
          );
          $("title").focus();
        }
      });
      timeline.append(column);
    }
    drawSelection();
  }
  async function load(initial = false) {
    const snapshot = await request("/public/calendar");
    data = { ...snapshot, clockOffset: +new Date(snapshot.now) - Date.now() };
    if (initial) {
      first = dayStart(data.start);
      $("zone").textContent =
        `Ваш часовой пояс · ${Intl.DateTimeFormat().resolvedOptions().timeZone}`;
      $("workspace").hidden = false;
      $("notice").textContent = "";
    }
    render();
    if (initial) $("viewport").scrollTop = 8 * 56;
  }
  $("prev").onclick = () => {
    first = addDays(first, -columns);
    if (first < dayStart(data.start)) first = dayStart(data.start);
    render();
  };
  $("next").onclick = () => {
    first = addDays(first, columns);
    render();
  };
  $("today").onclick = () => {
    first = dayStart(data.start);
    render();
  };
  for (const id of ["start-time", "end-time"])
    $(id).addEventListener("change", () => {
      if (!selection) return;
      const [sh, sm] = $("start-time").value.split(":").map(Number),
        [eh, em] = $("end-time").value.split(":").map(Number);
      if ([sh, sm, eh, em].some((v) => !Number.isFinite(v))) return;
      const start = atMinute(dayStart(selection.start), sh * 60 + sm);
      let end = atMinute(dayStart(selection.start), eh * 60 + em);
      if (end <= start) end = addDays(end, 1);
      select(start, end);
    });
  for (const id of ["title", "description"])
    $(id).addEventListener("input", () => {
      nonce = crypto.randomUUID();
    });
  $("form").addEventListener("submit", async (event) => {
    event.preventDefault();
    if (sending || expired) return;
    if (!valid(selection)) {
      $("form-error").textContent =
        "Этот интервал уже прошёл или занят. Выберите другое время.";
      return;
    }
    const title = $("title").value.trim();
    if (!title) {
      $("title").focus();
      return;
    }
    if (/attachment:/i.test(title + "\n" + $("description").value)) {
      $("form-error").textContent =
        "В гостевом предложении нельзя прикреплять файлы. Уберите ссылку на вложение.";
      return;
    }
    sending = true;
    $("submit").disabled = true;
    $("form-error").textContent = "";
    try {
      await request("/public/proposals", {
        nonce,
        title,
        description: $("description").value,
        start: selection.start.toISOString(),
        end: selection.end.toISOString(),
      });
      $("form").hidden = true;
      $("success").hidden = false;
      $("selection-title").textContent = "Готово";
      selection = null;
      drawSelection();
    } catch (error) {
      $("form-error").textContent = error.message;
      try {
        await load();
      } catch (refreshError) {
        $("notice").textContent = refreshError.message;
      }
    } finally {
      sending = false;
      $("submit").disabled = expired || !valid(selection);
    }
  });
  $("another").onclick = () => {
    $("success").hidden = true;
    $("selection-title").textContent = "Выберите ещё один интервал";
    $("selection-help").hidden = false;
    $("form").reset();
  };
  addEventListener("resize", () => {
    const next = matchMedia("(max-width:760px)").matches ? 1 : 7;
    if (next !== columns && data) {
      columns = next;
      render();
    }
  });
  setInterval(() => {
    if (!data || expired) return;
    const remaining = Math.ceil((new Date(data.expires) - serverNow()) / 1000);
    if (remaining <= 0) {
      unavailable();
      return;
    }
    $("expiry").textContent =
      `Доступ ещё ${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")}`;
  }, 1000);
  setInterval(() => {
    if (data && !expired && !document.hidden)
      load().catch((error) => {
        $("notice").textContent = error.message;
      });
  }, 60000);
  if (!/^[a-f0-9]{64}$/.test(token))
    unavailable("Откройте полную ссылку, которую прислал владелец календаря.");
  else
    load(true).catch((error) => {
      if (!expired)
        $("notice").textContent =
          "Не удалось открыть календарь. Проверьте соединение и обновите страницу.";
    });
})();
