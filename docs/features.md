# Features

[Documentation](README.md) · [Build from source](building.md)

## Your workspace

On desktop, Today combines a calendar with two pinned notes underneath. Drag the horizontal divider to resize the calendar and the vertical divider to change the notes' proportions. Double-click a divider to restore its default position. Sizes are saved on the current device.

The sidebar resizes from its right edge. Release it below half its original width to collapse it into a rail of icons; drag outward to expand it. Project colors remain clickable filters in the collapsed rail. **No project**, shown in the app's accent color, filters Today, Planner and Kanban to tasks without a project. Selecting a project replaces the current filter; clicking the selected filter again shows all projects and clears Planner search. The phone's project menu also includes **No project**. Narrow desktop layouts turn header actions into icons.

On phones, the bottom navigation runs **Kanban → Planner → Notes → Today**. Today opens by default. Two buttons near the bottom-right create an event or a note; their position stays consistent across sections. The pinned notes appear first in Notes. A new or recently opened ordinary note can temporarily appear above them for quick access.

## Calendar and planning

Choose day, three-day, week or month views. Today and Planner remember their views independently on each device. Horizontal swipes change the date range on phones; a wide week scrolls through its hidden columns before changing the range.

In Planner, select an unscheduled task and choose a time in the calendar. A click uses the default duration from settings, initially 30 minutes. Drag to choose a longer interval. On phones, hold until the haptic response and then drag; an ordinary swipe scrolls the calendar.

Desktop events move with the pointer and resize from either edge. On phones, holding an event reveals its resize handles. Completion and timer buttons remain usable on short events. Trackpad scrolling does not create a new event or move an existing one.

While dragging or resizing:

- A guide line and label show the exact target time in five-minute increments.
- The top and bottom 20% of the visible calendar scroll time continuously, faster near the edge.
- Moving an endpoint into the next day previews the continuation before release.
- Holding beyond a desktop calendar's left or right boundary for 650 ms changes the date range. On a narrow view, hidden columns of the current range are revealed first. Leaving the edge or cancelling the gesture stops the pending change.

A task can have several calendar blocks. Add another in the editor's expandable block section or split a block from the calendar menu. Title, description, project, status and total tracked time belong to the task; scheduling and reminders belong to its individual blocks.

In month view, choosing a date opens that day's schedule in a mobile sheet or desktop dialog. Select, move or resize an interval directly in the time grid. Existing events remain visible and overlaps are indicated. Only confirming the plan saves the block and its estimate; cancelling keeps the month view and the original task.

On desktop, drag the divider between the task list and calendar to change their proportions; double-click to reset it. On phones, the centered Tasks/Calendar switch sits at the bottom. Selecting a task opens the calendar; scheduling it returns to the remaining tasks while preserving the date and scroll position.

The event menu in the mobile planner includes **Remove from plan**. This removes the selected block, retaining the task and its tracked time. An ordinary task returns to Planner when it has no other current or future blocks. **Delete task** removes the task, its blocks and time entries.

Unfinished blocks ending before the start of today become plan history. Ordinary tasks with no other current/future blocks return to the unscheduled list. Historical blocks and tracked time remain available. Recurring instances stay in the calendar rather than returning to Planner. The current estimate is the sum of current blocks; all-day durations use real day boundaries, including daylight-saving changes.

## Tasks, projects and recurrence

Kanban has four states: **To Do, In Progress, Waiting and Done**. Drag cards with a mouse or hold and move them on a phone. Recurring instances are excluded from Kanban and the unscheduled list. A task can belong to one optional project; there is no priority field.

Done defaults to the last seven calendar days in the application's time zone. Choose 30 days or all history in the column header. Results appear newest first, in batches of up to 50. Reopening the board restores the seven-day filter. These are display limits: older tasks remain in the calendar, search, statistics and backups. Tasks without a completion date are available in the all-history view.

Planner lists new tasks first within the incoming-proposal and ordinary-task groups. Editing an older task does not move it to the top. A card's menu opens its editor; clicking the card selects it for planning. Incoming proposals are described in [calendar sharing](synchronization.md#calendar-sharing).

Creation and editing use the same form: a single-line title, compact date/time controls, recurrence and a reminder dropdown. The end date is shown only for events spanning multiple days. Projects appear as horizontal tags. Less-used block and time-entry controls are expandable; the description stays open at the bottom. Opening an event from the calendar edits the selected block's schedule and reminders.

Recurrence supports every N days, weeks, months or years, selected weekdays, a day of the month, or an ordinal weekday. Edits and deletions can apply to one instance, this and subsequent instances, or the entire series. Changing a schedule from an instance preserves already completed work. There is no separate recurrence end-date field; stop a series by deleting the remaining instances. Instances have independent statuses and time entries.

Create reminders using custom numbers of weeks, days, hours or minutes. Default reminders and the IANA time zone are configured in settings. Reminders support a ten-minute snooze. Planning settings save immediately; an invalid duration does not overwrite the last saved value, and save failures can be retried.

An `.ics` export from Google Calendar can be imported once with a preview and project selection. Reimporting the same data does not create duplicates. `RECURRENCE-ID` exceptions become separate tasks and exclude their original dates from the series. Unsupported `RDATE`, `EXRULE`, `RANGE` and some reminder forms are reported before import. This is an import feature, not a Google Calendar synchronization service.

## Time tracking

Start or stop tracking from a calendar card. The header control follows the active timer, including one started on another device after synchronization. With no active timer, it resumes the last calendar task tracked on this device; that choice survives a restart.

A synchronized timer can be stopped from another connected device. If its start has already synchronized, an offline stop records the actual button-press time and uploads it later. Independently started offline intervals can conflict; keep one version or merge them. Merging preserves breaks and counts overlapping time once within a task. Original intervals remain marked as excluded rather than being silently discarded.

Manual time entry opens the selected task's calendar: the plan is an outline, and tracked intervals use the overrun color. Draw several intervals, move or resize them, then confirm them together. Cancelling leaves the previous entries unchanged. **Track all available time** fills completed blocks and the elapsed portion of a currently running block. Future time cannot be tracked, and the action is unavailable when nothing has elapsed. Actual time can exceed the plan.

Tracked intervals appear alongside the calendar. Completing an ordinary task strikes it through; completing a birthday hides that year's instance. The completion action can also create a follow-up check task with the original description and project.

Phones expose the active timer on the lock screen through an iOS Live Activity or an Android notification. They show title, actual/estimated time, pause/resume and stop. Once actual time exceeds the plan, an overrun segment grows from the right: the accent share is `planned / actual`, and the overrun share is `(actual - planned) / actual`. See [platform behavior](platforms.md) for background-update limits.

## Working days

**Settings → Working day** defines the start, end and working weekdays; the default is Monday–Friday, 09:00–18:00. Dashed calendar lines with compact sun/moon markers show the boundaries. Their names and times appear on hover. Drag a marker on desktop, or hold and drag on a phone, to adjust that date in five-minute steps. Changes can be made retrospectively; clicking a marker does not open another editor.

Configured boundaries count automatically. A setting change applies from **yesterday in the application's time zone** onward, preserving earlier statistics. Further edits on the same day replace the same effective interval. Dates with manually adjusted boundaries keep those adjustments.

The end can fall on the following calendar day. An end time earlier than or equal to the start in settings means the next day, up to 24 clock hours. Actual intervals are limited to 25 hours to accommodate daylight-saving changes. The end marker appears on the next date, with its originating day and `+1` in the tooltip; midnight at a column boundary is shown as 24:00. The marker can cross day/week boundaries while respecting that duration limit.

Working-day boundaries are separate records. They do not create tasks or populate Kanban and Planner.

## Notes and live Markdown

Creating a note places the cursor in its body. The optional title appears above a thin divider and saves automatically. Without a title, the library and search use the first Markdown heading outside code blocks, or the first non-empty line if no heading exists. Pinned notes keep their own labels.

On a phone, a note opens as formatted text without the keyboard. Tap to place the cursor and type; hold to select text and use native copy/paste. A Done control stays above the keyboard. It or a tap outside the editor closes the keyboard while retaining the note's position. Links and checkboxes work without opening the keyboard. Creation buttons hide during text entry.

The live editor maintains one document with continuous selection and native input:

- Typing a space after `**bold text**` hides its markers; pressing Enter after a heading formats it. Returning the cursor to the markup reveals its source.
- Closed code blocks, images and standalone wiki links show previews outside the active input region.
- Arrow keys, Backspace/Delete and Select All work across the entire document, including blank paragraphs. Undo/redo applies to the whole note, including native iOS undo.
- Every Enter adds one line break. Internal whitespace is preserved; multiple trailing blank lines are reduced to one final newline when saved.
- Code blocks preserve indentation and blank lines. Long lines scroll horizontally. The copy control stays in the top-right of the visible code area while scrolling; it appears on hover on desktop and stays visible on phones. Shorter nested fence markers do not close an outer block.

Use `- [ ] subtask` and `- [x] completed` for checklists in notes and event descriptions. Completed items are struck through. Nested and loose lists work independently; Enter continues with an unchecked item, and Enter on an empty item ends the list. Read-only checkboxes cannot be changed, and code examples remain literal text. Checklist state lives in Markdown and does not create calendar tasks or change a parent event's status.

Plain `https://`, `http://`, `www.` and email addresses become links. Percent-encoded URL characters are preserved when opening them. Holding a link selects its source for editing; addresses inside code remain plain text. External Markdown images are not fetched automatically: add the image as an attachment instead.

Notes without a title or meaningful body are removed when leaving the screen, after pending autosaves finish. A title alone is enough to keep a note. Markdown and attachment links count as content. The pinned quick/reference notes are retained even when cleared. Deletions synchronize normally.

### Folders and links

Desktop notes are grouped in collapsible folders. Drag a note's handle to reorder it within a folder; folder menus control folder order. Select a folder to make it the destination for the general Create note action. Its menu also creates a note directly inside it. Removing a folder moves its notes to the unfiled group. Folder membership and order synchronize.

On phones, folder headings appear among the notes and collapse in place. The note menu can move a note to a folder or delete it with confirmation. Pinned notes offer Clear content rather than deletion.

Type `[[` to open note-link suggestions. Continue typing to filter titles/folders, then choose with a tap, a click, arrows plus Enter/Tab, or cancel with Escape. This also works in event descriptions, but not inside code.

| Syntax | Purpose |
| --- | --- |
| `[[Title]]` | Link by title |
| `[[Folder/Title]]` | Disambiguate folders |
| `[[Title|Label]]` | Use a custom label |
| `[[note:ID|Title]]` | Disambiguate identical titles in one folder |

Renaming a note, changing its first heading, or moving it updates unambiguous existing wiki links in notes, tasks and series within the same local transaction. Code and legacy `[Title](note:ID)` links are left unchanged; legacy links and `yggvion://note/ID` remain readable inside Markdown.

Standalone links show a preview card; inline links stay within their paragraph. Open note closes the preview/event dialog and navigates to the linked note in Notes. Save an event draft before leaving it. Ambiguous titles prompt a choice; missing notes show an explanation. Note-link URL schemes are not registered as OS entry points.

## Attachments

Paste text, images or files into notes and descriptions using Cmd/Ctrl+V or the editor's Paste menu. Multiple files, screenshots and native clipboard file representations are supported; pasted text replaces the selected text or enters at the cursor. Files can be up to **300 MiB** each. Folders are not packed automatically, and availability depends on what the source application places on the clipboard.

The attachment library is available from the desktop Notes library and the paperclip in the phone's top bar. Its Images/Files tabs also switch with a horizontal swipe. Images use a lazy thumbnail grid grouped by addition date in the app's time zone, newest first; older entries without a date appear in an earlier-items group. Names are searchable in both tabs.

Tap an image in a note or the library for a full-screen viewer with pinch/double-tap zoom. Text files up to 1 MiB can be read and copied in the app; other files can open in a system application. Opening the library closes the keyboard; returning preserves the note and scroll position.

On iOS, saved file paths are repaired at startup if an update moves the application container. Missing cached bytes can be downloaded again; previews use only files that are actually available. The reference note accepts pasted files only while editing is enabled.

The menu can remove unused files, and an unreferenced file can be deleted individually. References in personal records, recurring series, pinned notes and unresolved conflicts are considered and rechecked before deletion. A connected client must synchronize before cleanup; an unavailable server blocks it. With no server, cleanup is local. Existing backups keep their copies of removed files. See [attachment storage](architecture.md#attachment-catalog) for synchronization safeguards.

## Search

Cmd/Ctrl+F or Cmd/Ctrl+K searches titles, note bodies and event descriptions, including past and future records. A single letter performs exact-prefix search. Settings allow 0, 1 or 2 typos per entered word fragment, defaulting to 1; two-letter fragments allow at most one error. Missing/extra characters, substitutions and adjacent transpositions count. The untyped word ending is free, so a fragment can match before the word is complete. Fragments longer than 64 characters use exact-prefix search.

Results are ranked **note titles → note bodies → event titles → event descriptions**, with exact matches before one-/two-error matches inside each group. All query words must match the title to enter a title group; words spread between title and body enter a body group. Ranking happens before the 100-result limit, and duplicates are removed. Attached document contents and OCR are not indexed.

Click an event result to edit it. Its Go to action opens and highlights the current or nearest future block in the calendar, falling back to the latest past block. A month view switches to a day view for this navigation.

## Statistics

**Settings → Statistics** opens a separate dashboard. Choose 7, 30 or 90 days, earlier periods, or All time. All time begins with the earliest plan, tracked interval, working day or local activity record. Longer periods are grouped and chart point counts are bounded; 90-day views group by week.

The plan/actual line chart uses a dashed plan and an accent-colored actual line. Hover, tap or drag horizontally for exact values. Historical unfinished plans remain included. Intervals are split at calendar-day boundaries in the app's time zone, and actual time is clipped to now. Overall overlapping tracked intervals count once; project totals describe each project's own time, with an explanation when tasks overlap. Cancelled records and birthdays are excluded.

Estimate accuracy appears directly below that chart, followed by a full-width project breakdown. For each completed task planned in the selected period, compare its whole plan with all of its tracked time:

```text
absolute error = abs(actual - planned) / planned × 100%
```

The dashboard shows mean absolute error with equal weight per task, the count strictly above 10%, and separate averages for underestimated and overestimated tasks. Tasks without tracked time are excluded from percentages and counted separately. An expandable list shows up to eight tasks with the largest percentage errors. Missing values use a dash. Completed-task counts use current task status for tasks planned in the period, rather than guessed historical completion dates.

Work during the day shows the merged tracked hours and their percentage within working-day boundaries, using the schedule history and manual adjustments for each date. Today is clipped to now; work outside those boundaries has its own total. Start/end statistics include working days without tasks or timers once their boundary time has elapsed. Future boundaries and unscheduled non-working days are excluded.

Overnight work belongs to the day on which the working day starts, even after the last calendar date in the chosen period. Overlapping adjacent working days assign the overlap to the earlier one. End-time averages preserve day offsets: the average of 23:00 and 01:00 the next day is midnight the next day. The general plan/actual chart still splits by calendar dates.

Chart lines are smoothed without overshooting neighboring values. Each chart has its own hover-only information icon explaining its calculations; clicking or long-pressing it does not open another dialog.

### App activity

Local activity tracks active application use on the current device. Counting pauses after two minutes without input; checkpoints are saved every 30 seconds and when the app goes into the background. An unexpected exit can lose the last few seconds. This metric is separate from task tracking and is not synchronized to other devices or included in server snapshots. Local device backups include it.

The usage chart shows time and sessions, switching to minutes for short sessions. The activity calendar always covers the last 365 days, independent of the chart period. Accent brightness has five levels: none, under 5 minutes, 5–20 minutes, 20–60 minutes, and at least an hour. Weeks run horizontally and weekdays vertically from Monday. A tap shows the date and active duration. It also reports active-day count and current/best streaks within the year; yesterday's streak stays current until today ends.

On phones, the year scrolls horizontally and initially shows the latest months. Intervals are merged, future time is excluded, and the app's time zone/DST rules apply. Time spent editing notes, planning and operating the timer in the active window counts; a background task timer belongs to actual work time instead.

## Birthdays

A separate page under Settings manages names and birth dates with an age preview. Each birthday appears above timed events, automatically showing the age for that year. Marking it complete hides that year's instance without affecting future years. Birthdays never enter Kanban or Planner.

There is one reminder at 09:00 on the birthday in the app's time zone. February 29 is observed on February 28 in non-leap years. The current and next two years are expanded in advance, with more instances created as dates are viewed.

## Appearance and device preferences

The common accent color changes controls, navigation, highlights, input fields, logo and tasks without projects. It saves offline, synchronizes and updates open dialogs. Projects keep their own colors; calendar and Kanban cards have opaque backgrounds.

Dark is the default theme. Light mode applies to the entire interface and uses readable text shades and opaque light fills without changing the saved accent/project colors. Theme choice is local to the device.

Choose Russian, English, Spanish, German, Simplified Chinese or Hindi and an interface scale of 50%, 70%, 100%, 150% or 200%. Language, interface scale and calendar zoom are device-local. User-authored note content and project names are not translated.

Calendar zoom lives in Planning settings on both desktop and phone. The widest range fits a full day vertically; the closest view uses 216 logical pixels per hour. Interface scale also affects physical size. Month view has no vertical time zoom.

The shield/tree logo follows the accent in the interface. The macOS Dock icon changes while the app runs; Finder and the closed app retain the primary blue icon. iOS includes eight color variants selected through the system, with its standard confirmation message. A failed icon change can be retried without losing the chosen theme. Android, Windows and Linux system icons use the blue variant.

## Keyboard shortcuts

Use Cmd on macOS and Ctrl on Windows/Linux. F1 or the sidebar shortcut-help action opens the reference.

| Action | Shortcut |
| --- | --- |
| Search | Cmd/Ctrl+F or Cmd/Ctrl+K |
| New task | Cmd/Ctrl+N |
| New note | Cmd/Ctrl+Shift+N |
| Today / Planner / Kanban / Notes / Settings | Cmd/Ctrl+1 / 2 / 3 / 4 / 5 |
| Settings | Cmd/Ctrl+, |
| Pause active timer / resume last calendar task | Cmd/Ctrl+Shift+Space |
| Save a task from its non-empty title field | Enter |
| Move from the title to the description | Cmd/Ctrl+Enter |
| Paste text, images or files | Cmd/Ctrl+V |
| Close a dialog / cancel selection | Escape |

Workspace shortcuts remain available after finishing note/search input. They do not execute behind an open dialog.
