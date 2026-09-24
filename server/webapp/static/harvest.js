// ============================================================
// harvest.js — Client-side logic for the Harvest suggestion page
// Expects HARVEST_DATE global from template
// ============================================================

var harvestProjects = []; // loaded from /api/harvest/projects

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function formatTime(isoStr) {
  if (!isoStr) return '--:--';
  var match = isoStr.match(/T(\d{2}):(\d{2})/);
  if (!match) return '--:--';
  return match[1] + ':' + match[2];
}

// ============================================================
// NAVIGATION
// ============================================================

function navigateDay(delta) {
  var d = new Date(HARVEST_DATE);
  d.setDate(d.getDate() + delta);
  var str = d.toISOString().split('T')[0];
  navigateToDate(str);
}

function navigateToDate(dateStr) {
  window.location.href = '/harvest?date=' + dateStr;
}

function overlayStatus(text) {
  var sub = document.getElementById('harvest-overlay-sub');
  if (sub) sub.textContent = text;
}

function hideOverlay() {
  var overlay = document.getElementById('harvest-overlay');
  if (overlay) overlay.classList.add('hidden');
}

function toggleSection(name) {
  var body = document.getElementById(name + '-body');
  var toggle = document.getElementById(name + '-toggle');
  if (!body) return;
  body.classList.toggle('collapsed');
  if (toggle) toggle.style.transform = body.classList.contains('collapsed') ? 'rotate(-90deg)' : '';
}

// ============================================================
// PROJECTS
// ============================================================

async function fetchProjects() {
  try {
    var resp = await fetch('/api/harvest/projects');
    var data = await resp.json();
    harvestProjects = data.projects || [];
  } catch (err) {
    harvestProjects = [];
  }
}

function buildProjectSelect(selectedId, idx) {
  var html = '<select class="suggestion-select suggestion-project-select" data-idx="' + idx + '" onchange="onProjectChange(this)">';
  html += '<option value="">— Select project —</option>';
  for (var i = 0; i < harvestProjects.length; i++) {
    var p = harvestProjects[i];
    var sel = (selectedId && p.id == selectedId) ? ' selected' : '';
    var label = p.client ? p.client + ' — ' + p.name : p.name;
    html += '<option value="' + p.id + '"' + sel + '>' + escapeHtml(label) + '</option>';
  }
  html += '</select>';
  return html;
}

function buildTaskSelect(projectId, selectedTaskId, idx) {
  var tasks = [];
  for (var i = 0; i < harvestProjects.length; i++) {
    if (harvestProjects[i].id == projectId) {
      tasks = harvestProjects[i].tasks || [];
      break;
    }
  }

  var html = '<select class="suggestion-select suggestion-task-select" data-idx="' + idx + '">';
  if (tasks.length === 0) {
    html += '<option value="">— No tasks —</option>';
  } else {
    html += '<option value="">— Select task —</option>';
    for (var i = 0; i < tasks.length; i++) {
      var t = tasks[i];
      var sel = (selectedTaskId && t.id == selectedTaskId) ? ' selected' : '';
      html += '<option value="' + t.id + '"' + sel + '>' + escapeHtml(t.name) + '</option>';
    }
  }
  html += '</select>';
  return html;
}

function onProjectChange(selectEl) {
  var idx = selectEl.getAttribute('data-idx');
  var projectId = selectEl.value;
  var taskContainer = document.getElementById('task-select-' + idx);
  if (taskContainer) {
    taskContainer.innerHTML = buildTaskSelect(projectId, null, idx);
  }
}

// ============================================================
// CALENDAR
// ============================================================

async function fetchCalendar() {
  var loading = document.getElementById('calendar-loading');
  var eventsEl = document.getElementById('calendar-events');
  var countEl = document.getElementById('calendar-count');

  try {
    var resp = await fetch('/api/calendar/' + HARVEST_DATE);
    var data = await resp.json();
    if (loading) loading.style.display = 'none';

    if (data.error || !data.events || data.events.length === 0) {
      eventsEl.innerHTML = '<div class="harvest-empty">'
        + (data.error ? 'Could not load calendar' : 'No events') + '</div>';
      if (countEl) countEl.textContent = '';
      return;
    }

    var scheduled = data.events.filter(function(ev) {
      var isAllDay = !ev.start || ev.start.indexOf('T') === -1;
      return !isAllDay && ev.showAs !== 'free';
    });

    if (countEl) {
      countEl.textContent = scheduled.length + ' event' + (scheduled.length !== 1 ? 's' : '');
    }

    if (scheduled.length === 0) {
      eventsEl.innerHTML = '<div class="harvest-empty">No scheduled events</div>';
      return;
    }

    eventsEl.innerHTML = scheduled.map(function(ev) {
      var tentative = ev.showAs === 'tentative' ? ' tentative' : '';
      var attendees = (ev.attendees || []).length > 0
        ? '<span class="cal-attendees">' + ev.attendees.map(escapeHtml).join(', ') + '</span>'
        : '';
      return '<div class="calendar-event' + tentative + '">'
        + '<span class="cal-time">' + formatTime(ev.start) + ' - ' + formatTime(ev.end) + '</span>'
        + '<span class="cal-subject">' + escapeHtml(ev.subject) + '</span>'
        + attendees
        + '</div>';
    }).join('');
  } catch (err) {
    if (loading) loading.style.display = 'none';
    eventsEl.innerHTML = '<div class="harvest-empty">Calendar error</div>';
  }
}

// ============================================================
// DIARY TRANSCRIPT
// ============================================================

function fetchDiary(transcriptId) {
  var loading = document.getElementById('diary-loading');
  var textEl = document.getElementById('diary-text');
  var countEl = document.getElementById('diary-count');

  if (transcriptId) {
    fetch('/review/' + transcriptId)
      .then(function() {
        // We just know there's a transcript — show link
        if (loading) loading.style.display = 'none';
        if (countEl) countEl.textContent = 'found';
      });
  }
}

// ============================================================
// SUGGESTIONS
// ============================================================

async function fetchSuggestions() {
  var loading = document.getElementById('suggestions-loading');
  var listEl = document.getElementById('suggestions-list');
  var countEl = document.getElementById('entry-count');
  var hoursEl = document.getElementById('total-hours');
  var errorsEl = document.getElementById('harvest-errors');
  var patternEl = document.getElementById('pattern-info');
  var diaryLoading = document.getElementById('diary-loading');
  var diaryTextEl = document.getElementById('diary-text');
  var diaryCountEl = document.getElementById('diary-count');

  try {
    var resp = await fetch('/api/harvest/suggest?date=' + HARVEST_DATE);
    var data = await resp.json();
    if (loading) loading.style.display = 'none';

    // Show diary info
    if (diaryLoading) diaryLoading.style.display = 'none';
    if (data.transcript_id) {
      if (diaryCountEl) diaryCountEl.textContent = 'found';
      if (diaryTextEl) {
        diaryTextEl.innerHTML = '<a href="/review/' + data.transcript_id
          + '" class="harvest-diary-link">Open transcript in review</a>';
      }
    } else {
      if (diaryCountEl) diaryCountEl.textContent = '';
      if (diaryTextEl) {
        diaryTextEl.innerHTML = '<div class="harvest-empty">No transcript for this date</div>';
      }
    }

    // Errors
    if (data.errors && data.errors.length > 0) {
      errorsEl.innerHTML = data.errors.map(function(e) {
        return '<div class="harvest-error">' + escapeHtml(e) + '</div>';
      }).join('');
    }

    // Pattern info
    if (patternEl) {
      patternEl.textContent = data.pattern_db_loaded
        ? 'Pattern DB loaded from recent entries'
        : 'No pattern data — load entries on Data page to enable';
    }

    var suggestions = data.suggestions || [];
    if (countEl) {
      countEl.textContent = suggestions.length + ' entr' + (suggestions.length !== 1 ? 'ies' : 'y');
    }
    if (hoursEl) {
      hoursEl.textContent = (data.total_hours || 0).toFixed(2) + 'h';
    }

    if (suggestions.length === 0) {
      listEl.innerHTML = '<div class="harvest-empty">No suggestions generated</div>';
      return;
    }

    listEl.innerHTML = suggestions.map(function(s, i) {
      var sourceClass = s.confidence === 'high' ? 'source-high'
        : s.confidence === 'medium' ? 'source-medium' : 'source-low';
      var sourceLabel = s.source || 'unknown';

      var timeInfo = '';
      if (s.start) {
        timeInfo = '<span class="suggestion-time">'
          + formatTime(s.start) + (s.end ? ' - ' + formatTime(s.end) : '')
          + '</span>';
      }

      var projectId = s.project ? s.project.id : null;
      var taskId = s.task ? s.task.id : null;

      return '<div class="suggestion-card ' + sourceClass + '">'
        + '<div class="suggestion-header">'
        + timeInfo
        + '<span class="suggestion-hours">' + s.hours.toFixed(2) + 'h</span>'
        + '<span class="suggestion-source ' + sourceClass + '">' + escapeHtml(sourceLabel) + '</span>'
        + '</div>'
        + '<div class="suggestion-project">'
        + buildProjectSelect(projectId, i)
        + '</div>'
        + '<div class="suggestion-task" id="task-select-' + i + '">'
        + buildTaskSelect(projectId, taskId, i)
        + '</div>'
        + '<div class="suggestion-notes">'
        + '<input type="text" value="' + escapeHtml(s.notes || '') + '" '
        + 'class="suggestion-notes-input" data-idx="' + i + '">'
        + '</div>'
        + '</div>';
    }).join('');
  } catch (err) {
    if (loading) loading.style.display = 'none';
    listEl.innerHTML = '<div class="harvest-error">Failed to load suggestions: '
      + escapeHtml(err.message) + '</div>';
  }
}

// ============================================================
// INIT
// ============================================================

async function initHarvest() {
  overlayStatus('Loading projects...');
  await fetchProjects();

  overlayStatus('Fetching calendar...');
  await fetchCalendar();

  overlayStatus('Loading Harvest data & generating suggestions...');
  await fetchSuggestions();

  hideOverlay();
}

if (typeof HARVEST_DATE !== 'undefined') {
  initHarvest();
}
