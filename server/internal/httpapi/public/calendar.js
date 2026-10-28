"use strict";
(() => {
  // Guest language follows the browser. All text is local; no translation requests.
  const languages = ["ru", "en", "es", "de", "zh", "hi"];
  const language = (navigator.languages || [navigator.language])
    .map((value) => value.toLowerCase().split("-")[0])
    .find((value) => languages.includes(value)) || "en";
  const messages = {
  "Согласуем время": [
    "Let’s find a time",
    "Acordemos una hora",
    "Finden wir einen Termin",
    "一起约个时间",
    "समय तय करें"
  ],
  "Приватное приглашение": [
    "Private invitation",
    "Invitación privada",
    "Private Einladung",
    "私人邀请",
    "निजी आमंत्रण"
  ],
  "Выберите свободный интервал и предложите встречу.": [
    "Choose a free slot and suggest a meeting.",
    "Elige un intervalo libre y propón una reunión.",
    "Wähle einen freien Zeitraum und schlage ein Treffen vor.",
    "选择空闲时段并提出会面建议。",
    "खाली समय चुनें और मुलाकात का प्रस्ताव दें।"
  ],
  "Открываем календарь…": [
    "Opening calendar…",
    "Abriendo calendario…",
    "Kalender wird geöffnet…",
    "正在打开日历…",
    "कैलेंडर खोल रहे हैं…"
  ],
  "Занятость календаря": [
    "Calendar availability",
    "Disponibilidad del calendario",
    "Kalenderverfügbarkeit",
    "日历空闲时间",
    "कैलेंडर की उपलब्धता"
  ],
  "Предыдущие дни": [
    "Previous days",
    "Días anteriores",
    "Vorherige Tage",
    "前几天",
    "पिछले दिन"
  ],
  "Следующие дни": [
    "Next days",
    "Días siguientes",
    "Nächste Tage",
    "后几天",
    "अगले दिन"
  ],
  "Сегодня": [
    "Today",
    "Hoy",
    "Heute",
    "今天",
    "आज"
  ],
  "Занято": [
    "Busy",
    "Ocupado",
    "Belegt",
    "忙碌",
    "व्यस्त"
  ],
  "Предложено": [
    "Proposed",
    "Propuesto",
    "Vorgeschlagen",
    "已提议",
    "प्रस्तावित"
  ],
  "Подтверждено": [
    "Confirmed",
    "Confirmado",
    "Bestätigt",
    "已确认",
    "पुष्टि की गई"
  ],
  "Отклонено": [
    "Declined",
    "Rechazado",
    "Abgelehnt",
    "已拒绝",
    "अस्वीकृत"
  ],
  "Перенесено владельцем": [
    "Rescheduled by owner",
    "Reprogramado por el propietario",
    "Vom Eigentümer verschoben",
    "所有者已改期",
    "स्वामी ने समय बदला"
  ],
  "Нажмите или протяните интервал. На телефоне — удерживайте для выделения.": [
    "Click or drag a time slot. On a phone, hold to select.",
    "Pulsa o arrastra un intervalo. En el teléfono, mantén pulsado para seleccionar.",
    "Klicke oder ziehe einen Zeitraum. Auf dem Handy zum Auswählen gedrückt halten.",
    "点击或拖动以选择时段。在手机上长按选择。",
    "समय चुनने के लिए क्लिक करें या खींचें। फ़ोन पर दबाकर रखें।"
  ],
  "ВАШЕ ПРЕДЛОЖЕНИЕ": [
    "YOUR PROPOSAL",
    "TU PROPUESTA",
    "DEIN VORSCHLAG",
    "你的提议",
    "आपका प्रस्ताव"
  ],
  "Начните с времени": [
    "Start with a time",
    "Empieza por la hora",
    "Wähle zuerst eine Zeit",
    "先选时间",
    "पहले समय चुनें"
  ],
  "Свободные промежутки открыты для ваших планов.": [
    "Free slots are open for your plans.",
    "Los intervalos libres están disponibles para tus planes.",
    "Freie Zeiträume stehen für deine Pläne bereit.",
    "你可以在空闲时段安排计划。",
    "खाली समय में अपनी योजना बना सकते हैं।"
  ],
  "Начало": [
    "Start",
    "Inicio",
    "Beginn",
    "开始",
    "शुरू"
  ],
  "Окончание": [
    "End",
    "Fin",
    "Ende",
    "结束",
    "समाप्ति"
  ],
  "Название встречи": [
    "Meeting title",
    "Título de la reunión",
    "Titel des Treffens",
    "会面标题",
    "मुलाकात का शीर्षक"
  ],
  "Например, обсудить проект": [
    "For example, discuss a project",
    "Por ejemplo, comentar un proyecto",
    "Zum Beispiel: Projekt besprechen",
    "例如，讨论项目",
    "जैसे, परियोजना पर चर्चा"
  ],
  "Описание": [
    "Description",
    "Descripción",
    "Beschreibung",
    "描述",
    "विवरण"
  ],
  "· необязательно": [
    "· optional",
    "· opcional",
    "· optional",
    "· 可选",
    "· वैकल्पिक"
  ],
  "Что стоит знать перед встречей? Только текст, без вложений.": [
    "What should we know before the meeting? Text only, no attachments.",
    "¿Qué conviene saber antes de la reunión? Solo texto, sin adjuntos.",
    "Was sollte man vor dem Treffen wissen? Nur Text, keine Anhänge.",
    "会面前需要了解什么？仅限文字，不含附件。",
    "मुलाकात से पहले क्या जानना चाहिए? केवल टेक्स्ट, कोई अटैचमेंट नहीं।"
  ],
  "Предложить встречу": [
    "Suggest a meeting",
    "Proponer reunión",
    "Treffen vorschlagen",
    "提议会面",
    "मुलाकात प्रस्तावित करें"
  ],
  "Это предложение. Встреча появится в календаре после подтверждения владельцем.": [
    "This is a proposal. The meeting will appear in the calendar once the owner confirms it.",
    "Esto es una propuesta. La reunión aparecerá en el calendario cuando el propietario la confirme.",
    "Dies ist ein Vorschlag. Das Treffen erscheint nach Bestätigung durch den Eigentümer im Kalender.",
    "这是一项提议。所有者确认后，会面才会出现在日历中。",
    "यह एक प्रस्ताव है। स्वामी की पुष्टि के बाद मुलाकात कैलेंडर में दिखाई देगी।"
  ],
  "Предложение отправлено": [
    "Proposal sent",
    "Propuesta enviada",
    "Vorschlag gesendet",
    "提议已发送",
    "प्रस्ताव भेज दिया गया"
  ],
  "Время отмечено в календаре. Статус обновится после ответа владельца.": [
    "The slot is marked in the calendar. Its status will update when the owner responds.",
    "El intervalo está marcado en el calendario. El estado se actualizará cuando responda el propietario.",
    "Der Zeitraum ist im Kalender markiert. Der Status ändert sich nach der Antwort des Eigentümers.",
    "该时段已标记在日历中。所有者回复后状态会更新。",
    "समय कैलेंडर में चिह्नित है। स्वामी के जवाब देने पर स्थिति अपडेट होगी।"
  ],
  "Предложить ещё": [
    "Suggest another",
    "Proponer otra",
    "Weiteren Vorschlag machen",
    "再提议一个",
    "एक और प्रस्ताव दें"
  ],
  "Ваши предложения": [
    "Your proposals",
    "Tus propuestas",
    "Deine Vorschläge",
    "你的提议",
    "आपके प्रस्ताव"
  ],
  "Ссылка действует один час": [
    "This link is valid for one hour",
    "El enlace es válido durante una hora",
    "Der Link ist eine Stunde gültig",
    "链接有效期为一小时",
    "यह लिंक एक घंटे के लिए मान्य है"
  ],
  "Срок приглашения закончился. Попросите владельца прислать новую ссылку.": [
    "The invitation has expired. Ask the owner for a new link.",
    "La invitación ha caducado. Pide un nuevo enlace al propietario.",
    "Die Einladung ist abgelaufen. Bitte den Eigentümer um einen neuen Link.",
    "邀请已过期。请向所有者索取新链接。",
    "आमंत्रण की समय-सीमा समाप्त हो गई है। स्वामी से नया लिंक माँगें।"
  ],
  "Приглашение недоступно": [
    "Invitation unavailable",
    "Invitación no disponible",
    "Einladung nicht verfügbar",
    "邀请不可用",
    "आमंत्रण उपलब्ध नहीं है"
  ],
  "Ссылка недоступна": [
    "Link unavailable",
    "Enlace no disponible",
    "Link nicht verfügbar",
    "链接不可用",
    "लिंक उपलब्ध नहीं है"
  ],
  "Слишком много запросов или предложений. Попробуйте позже.": [
    "Too many requests or proposals. Try again later.",
    "Demasiadas solicitudes o propuestas. Inténtalo más tarde.",
    "Zu viele Anfragen oder Vorschläge. Versuche es später erneut.",
    "请求或提议过多，请稍后重试。",
    "बहुत अधिक अनुरोध या प्रस्ताव हैं। बाद में फिर कोशिश करें।"
  ],
  "Это время уже занято. Выберите другой интервал.": [
    "This time is already taken. Choose another slot.",
    "Este horario ya está ocupado. Elige otro intervalo.",
    "Diese Zeit ist bereits belegt. Wähle einen anderen Zeitraum.",
    "该时段已被占用，请选择其他时间。",
    "यह समय पहले से व्यस्त है। कोई दूसरा समय चुनें।"
  ],
  "Не удалось отправить запрос. Проверьте время и попробуйте ещё раз.": [
    "Could not send the request. Check the time and try again.",
    "No se pudo enviar la solicitud. Comprueba la hora e inténtalo de nuevo.",
    "Die Anfrage konnte nicht gesendet werden. Prüfe die Zeit und versuche es erneut.",
    "无法发送请求。请检查时间后重试。",
    "अनुरोध नहीं भेजा जा सका। समय जाँचें और फिर कोशिश करें।"
  ],
  "Выберите свободное время в будущем в пределах приглашения.": [
    "Choose a future free slot within the invitation’s range.",
    "Elige un horario libre futuro dentro del período de la invitación.",
    "Wähle einen freien zukünftigen Zeitraum innerhalb der Einladung.",
    "请选择邀请范围内未来的空闲时段。",
    "आमंत्रण की अवधि में आगे का कोई खाली समय चुनें।"
  ],
  "Этот интервал уже прошёл или занят. Выберите другое время.": [
    "This slot is in the past or taken. Choose another time.",
    "Este intervalo ya ha pasado o está ocupado. Elige otra hora.",
    "Dieser Zeitraum liegt in der Vergangenheit oder ist belegt. Wähle eine andere Zeit.",
    "该时段已过去或已被占用。请选择其他时间。",
    "यह समय बीत चुका है या व्यस्त है। कोई दूसरा समय चुनें।"
  ],
  "В гостевом предложении нельзя прикреплять файлы. Уберите ссылку на вложение.": [
    "Guest proposals cannot include attachments. Remove the attachment link.",
    "Las propuestas de invitados no admiten archivos adjuntos. Elimina el enlace al adjunto.",
    "Gastvorschläge dürfen keine Anhänge enthalten. Entferne den Anhang-Link.",
    "访客提议不能包含附件。请移除附件链接。",
    "अतिथि प्रस्तावों में फ़ाइलें नहीं जोड़ सकते। अटैचमेंट लिंक हटाएँ।"
  ],
  "Готово": [
    "Done",
    "Listo",
    "Fertig",
    "完成",
    "हो गया"
  ],
  "Выберите ещё один интервал": [
    "Choose another slot",
    "Elige otro intervalo",
    "Wähle einen weiteren Zeitraum",
    "选择另一个时段",
    "एक और समय चुनें"
  ],
  "Откройте полную ссылку, которую прислал владелец календаря.": [
    "Open the full link sent by the calendar owner.",
    "Abre el enlace completo enviado por el propietario del calendario.",
    "Öffne den vollständigen Link des Kalendereigentümers.",
    "请打开日历所有者发送的完整链接。",
    "कैलेंडर के स्वामी द्वारा भेजा गया पूरा लिंक खोलें।"
  ],
  "Не удалось открыть календарь. Проверьте соединение и обновите страницу.": [
    "Could not open the calendar. Check your connection and reload the page.",
    "No se pudo abrir el calendario. Comprueba la conexión y recarga la página.",
    "Der Kalender konnte nicht geöffnet werden. Prüfe die Verbindung und lade die Seite neu.",
    "无法打开日历。请检查网络并刷新页面。",
    "कैलेंडर नहीं खोला जा सका। कनेक्शन जाँचें और पेज रीफ़्रेश करें।"
  ],
  "{0}. Enter — предложить время, стрелки — изменить начало.": [
    "{0}. Enter to propose a time, arrow keys to change the start.",
    "{0}. Intro para proponer una hora, flechas para cambiar el inicio.",
    "{0}. Eingabe zum Vorschlagen, Pfeiltasten zum Ändern des Beginns.",
    "{0}。按回车提议时间，方向键调整开始时间。",
    "{0}। समय प्रस्तावित करने के लिए Enter, शुरुआत बदलने के लिए तीर कुंजियाँ।"
  ],
  "Ваш часовой пояс · {0}": [
    "Your time zone · {0}",
    "Tu zona horaria · {0}",
    "Deine Zeitzone · {0}",
    "你的时区 · {0}",
    "आपका समय क्षेत्र · {0}"
  ],
  "Доступ ещё {0}": [
    "Available for {0}",
    "Disponible durante {0}",
    "Noch {0} verfügbar",
    "剩余 {0}",
    "{0} तक उपलब्ध"
  ]
};
  const t = (message, ...values) => {
    const index = languages.indexOf(language) - 1;
    const translated = index < 0 || !Object.hasOwn(messages, message)
      ? message : messages[message][index];
    return translated.replace(/\{(\d+)\}/g, (match, i) =>
      Number(i) < values.length ? String(values[i]) : match);
  };
  document.documentElement.lang = language;
  document.title = t("Согласуем время") + " · Yggvion";
  // Translate only the initial, server-owned markup, before any guest content arrives.
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode;
    const source = node.textContent.trim().replace(/\s+/g, " ");
    if (Object.hasOwn(messages, source)) {
      node.textContent = node.textContent.replace(/\S[\s\S]*\S|\S/, t(source));
    }
  }
  for (const element of document.querySelectorAll("[aria-label], [placeholder]")) {
    for (const attribute of ["aria-label", "placeholder"]) {
      const value = element.getAttribute(attribute);
      if (value && Object.hasOwn(messages, value)) element.setAttribute(attribute, t(value));
    }
  }
  const $ = (id) => document.getElementById(id);
  const token = location.hash.slice(1);
  let data,
    first,
    selection,
    nonce,
    sending = false,
    expired = false;
  let refreshing = false,
    dragging = false,
    revision = 0;
  const statuses = {
    pending: t("Предложено"),
    accepted: t("Подтверждено"),
    declined: t("Отклонено"),
    rescheduled: t("Перенесено владельцем"),
  };
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
    new Date(value).toLocaleTimeString(language, {
      hour: "2-digit",
      minute: "2-digit",
    });
  const dateLabel = (value) =>
    new Date(value).toLocaleDateString(language, {
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
    message = t("Срок приглашения закончился. Попросите владельца прислать новую ссылку."),
  ) {
    expired = true;
    $("notice").textContent = message;
    $("workspace").hidden = true;
    $("timeline").replaceChildren();
    $("proposal-list").replaceChildren();
    $("expiry").textContent = t("Приглашение недоступно");
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
      throw Error(t("Ссылка недоступна"));
    }
    if (response.status === 429)
      throw Error(t("Слишком много запросов или предложений. Попробуйте позже."));
    if (response.status === 409)
      throw Error(t("Это время уже занято. Выберите другой интервал."));
    if (!response.ok)
      throw Error(
        t("Не удалось отправить запрос. Проверьте время и попробуйте ещё раз."),
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
    if (sending || expired) return;
    selection = { start, end };
    nonce = crypto.randomUUID();
    $("selection-title").textContent = t("Предложить встречу");
    $("selection-help").hidden = true;
    $("success").hidden = true;
    $("form").hidden = false;
    $("selected-time").textContent =
      `${dateLabel(start)} · ${time(start)} — ${+dayStart(start) === +dayStart(end) ? "" : dateLabel(end) + " · "}${time(end)}`;
    $("start-time").value = inputTime(start);
    $("end-time").value = inputTime(end);
    $("form-error").textContent = valid(selection)
      ? ""
      : t("Выберите свободное время в будущем в пределах приглашения.");
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
    block.title = text;
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
          day.toLocaleDateString(language, { weekday: "short" }),
        );
      head.append(node("b", "", day.getDate()));
      heads.append(head);
      const column = node("div", "day-column");
      column.dataset.day = +day;
      column.tabIndex = 0;
      column.setAttribute(
        "aria-label",
        t("{0}. Enter — предложить время, стрелки — изменить начало.", dateLabel(day)),
      );
      for (const busy of data.busy)
        paintBlock(
          column,
          new Date(busy.start),
          new Date(busy.end),
          "busy-block",
          t("Занято"),
        );
      for (const proposal of data.proposals || []) {
        if (proposal.status !== "pending" && proposal.status !== "accepted")
          continue;
        paintBlock(
          column,
          new Date(proposal.start),
          new Date(proposal.end),
          `proposal-block ${proposal.status}`,
          `${statuses[proposal.status]} · ${time(proposal.start)}–${time(proposal.end)}`,
        );
      }
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
        dragging = true;
        originY = event.clientY;
        anchor = slot(event);
        const begin = () => {
          active = dragging = true;
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
        active = dragging = false;
      });
      column.addEventListener("pointercancel", () => {
        clearTimeout(wait);
        active = dragging = false;
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
    const receipts = $("proposal-list");
    receipts.replaceChildren();
    const proposals = data.proposals || [];
    $("proposals").hidden = proposals.length === 0;
    for (const p of proposals) {
      if (!Object.hasOwn(statuses, p.status)) continue;
      const row = node("div", "proposal-receipt");
      row.append(
        node("div", "receipt-time", `${dateLabel(p.start)} · ${time(p.start)}–${time(p.end)}`),
      );
      row.append(node("span", `receipt-status ${p.status}`, statuses[p.status]));
      receipts.append(row);
    }
  }
  async function load(initial = false) {
    if (refreshing || dragging || expired) return;
    refreshing = true;
    const requestedRevision = revision;
    try {
      const snapshot = await request("/public/calendar");
      if (expired || dragging || requestedRevision !== revision) return;
      data = { ...snapshot, clockOffset: +new Date(snapshot.now) - Date.now() };
      if (initial) {
        first = dayStart(data.start);
        $("zone").textContent =
          t("Ваш часовой пояс · {0}", Intl.DateTimeFormat().resolvedOptions().timeZone);
        $("workspace").hidden = false;
        $("notice").textContent = "";
      }
      render();
      $("notice").textContent = "";
      if (selection) {
        $("submit").disabled = sending || !valid(selection);
        if (!valid(selection))
          $("form-error").textContent = t("Это время уже занято. Выберите другой интервал.");
      }
      if (initial) $("viewport").scrollTop = 8 * 56;
    } finally {
      refreshing = false;
    }
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
        t("Этот интервал уже прошёл или занят. Выберите другое время.");
      return;
    }
    const title = $("title").value.trim();
    if (!title) {
      $("title").focus();
      return;
    }
    if (/attachment:/i.test(title + "\n" + $("description").value)) {
      $("form-error").textContent =
        t("В гостевом предложении нельзя прикреплять файлы. Уберите ссылку на вложение.");
      return;
    }
    sending = true;
    $("submit").disabled = true;
    $("form-error").textContent = "";
    const proposal = {
      nonce,
      start: selection.start.toISOString(),
      end: selection.end.toISOString(),
      status: "pending",
    };
    try {
      await request("/public/proposals", {
        nonce: proposal.nonce,
        title,
        description: $("description").value,
        start: proposal.start,
        end: proposal.end,
      });
      // The server has reserved this interval. Paint it immediately, even if
      // the following refresh cannot reach the network.
      revision++;
      data.proposals = [
        ...(data.proposals || []).filter((p) => p.nonce !== proposal.nonce),
        proposal,
      ];
      data.busy.push({ start: proposal.start, end: proposal.end });
      $("form").hidden = true;
      $("success").hidden = false;
      $("selection-title").textContent = t("Готово");
      selection = null;
      render();
      await load().catch((error) => {
        if (!expired) $("notice").textContent = error.message;
      });
    } catch (error) {
      $("form-error").textContent = error.message;
      try {
        await load();
        if (data?.proposals?.some((p) => p.nonce === proposal.nonce)) {
          $("form").hidden = true;
          $("success").hidden = false;
          $("selection-title").textContent = t("Готово");
          $("form-error").textContent = "";
          selection = null;
          drawSelection();
        }
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
    $("selection-title").textContent = t("Выберите ещё один интервал");
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
      t("Доступ ещё {0}", `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, "0")}`);
  }, 1000);
  setInterval(() => {
    if (data && !expired && !document.hidden && !sending && !dragging)
      load().catch((error) => {
        $("notice").textContent = error.message;
      });
  }, 15000);
  document.addEventListener("visibilitychange", () => {
    if (data && !expired && !document.hidden && !sending)
      load().catch((error) => {
        if (!expired) $("notice").textContent = error.message;
      });
  });
  if (!/^[a-f0-9]{64}$/.test(token))
    unavailable(t("Откройте полную ссылку, которую прислал владелец календаря."));
  else
    load(true).catch((error) => {
      if (!expired)
        $("notice").textContent =
          t("Не удалось открыть календарь. Проверьте соединение и обновите страницу.");
    });
})();
