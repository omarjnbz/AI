// === Configuration ===
// Replace with your actual server endpoint and token when ready
const API_BASE = null; // e.g. "http://192.168.1.100:8080/api"
const API_TOKEN = null; // e.g. "xK9mQ2vL8pN4wR7tY1bF6hJ3" (must match server)

// === Heartbeat Settings (synced to Nagios 5-min check cycle) ===
const HEARTBEAT_INTERVAL = 300;   // 5 minutes — matches Nagios refresh rate
const DATA_REFRESH_INTERVAL = 300; // 5 minutes — pull new data each Nagios cycle
const CPU_THRESHOLD = 90;
const MEMORY_THRESHOLD = 90;
const MAX_MISSED_HEARTBEATS = 3;  // mark offline after 15 min of no response

// === State ===
var missedHeartbeats = 0;
var heartbeatCountdown = HEARTBEAT_INTERVAL;
var heartbeatTimerId = null;
var countdownTimerId = null;
var dataRefreshTimerId = null;
var previousConnections = null;
var alerts = [];
var alertIdCounter = 0;

// === Mock Data (used when API_BASE is null) ===
function getMockHealthData() {
  return {
    status: "online",
    uptime: "14d 7h 32m",
    cpu: 42 + Math.floor(Math.random() * 15),
    memory: 60 + Math.floor(Math.random() * 20),
    diskIO: "128 MB/s",
  };
}

function getMockConnectivityData() {
  return {
    status: "online",
    activeConnections: 170 + Math.floor(Math.random() * 30),
    totalAgents: 312,
    avgLatency: Math.floor(15 + Math.random() * 20) + "ms",
    packetLoss: (Math.random() * 0.1).toFixed(2) + "%",
    connectionType: "Non Site-to-Site",
  };
}

function getMockLogsData() {
  var statuses = ["success", "success", "success", "pending", "failed"];
  var vendors = ["Vendor A — Cisco ASA", "Vendor B — Palo Alto", "Vendor C — Fortinet", "Vendor D — Check Point"];
  var actions = ["Call Activation", "Health Probe", "Tunnel Re-key", "Log Rotation", "Connectivity Check"];
  var logs = [];
  for (var i = 0; i < 6; i++) {
    var d = new Date(Date.now() - i * 300000);
    logs.push({
      timestamp: d.toISOString().replace("T", " ").substring(0, 19),
      vendor: vendors[Math.floor(Math.random() * vendors.length)],
      action: actions[Math.floor(Math.random() * actions.length)],
      status: statuses[Math.floor(Math.random() * statuses.length)],
    });
  }
  return { status: "online", logs: logs };
}

function getMockHeartbeat() {
  return { alive: true, timestamp: new Date().toISOString() };
}

// === Data Fetching ===
async function fetchData(endpoint, mockFn) {
  if (!API_BASE) {
    return mockFn();
  }
  try {
    var headers = {};
    if (API_TOKEN) headers["Authorization"] = "Bearer " + API_TOKEN;
    var res = await fetch(API_BASE + "/" + endpoint, { headers: headers });
    if (res.status === 401) throw new Error("Unauthorized — check your API token");
    if (!res.ok) throw new Error("HTTP " + res.status);
    return await res.json();
  } catch (err) {
    console.error("Fetch failed for " + endpoint + ":", err);
    return null;
  }
}

// === Alerts System ===
function addAlert(type, message) {
  var id = ++alertIdCounter;
  var existing = alerts.find(function (a) { return a.message === message && a.type === type; });
  if (existing) return;

  alerts.push({ id: id, type: type, message: message, time: new Date() });
  if (alerts.length > 8) alerts.shift();
  renderAlerts();
}

function dismissAlert(id) {
  alerts = alerts.filter(function (a) { return a.id !== id; });
  renderAlerts();
}

function clearAlertByMessage(message) {
  alerts = alerts.filter(function (a) { return a.message !== message; });
  renderAlerts();
}

function renderAlerts() {
  var container = document.getElementById("alerts-container");
  if (!container) return;
  if (alerts.length === 0) {
    container.innerHTML = "";
    return;
  }
  var icons = { critical: "&#9888;", warning: "&#9888;", info: "&#8505;" };
  container.innerHTML = alerts.map(function (a) {
    var timeStr = a.time.toLocaleTimeString();
    return '<div class="alert-item ' + a.type + '">' +
      '<span class="alert-icon">' + icons[a.type] + '</span>' +
      '<span class="alert-text">' + a.message + '</span>' +
      '<span class="alert-time">' + timeStr + '</span>' +
      '<button class="alert-dismiss" onclick="dismissAlert(' + a.id + ')">&times;</button>' +
      '</div>';
  }).join("");
}

// === Heartbeat ===
function setHeartbeatState(state) {
  var dot = document.getElementById("heartbeat-dot");
  var label = document.getElementById("heartbeat-label");
  if (!dot || !label) return;

  dot.className = "heartbeat-dot";
  if (state === "alive") {
    dot.classList.add("alive");
    label.textContent = "Server Online";
    label.style.color = "#16a34a";
  } else if (state === "degraded") {
    dot.classList.add("degraded");
    label.textContent = "Degraded";
    label.style.color = "#ca8a04";
  } else {
    dot.classList.add("dead");
    label.textContent = "Server Offline";
    label.style.color = "#ef4444";
  }
}

async function heartbeatPing() {
  var data = await fetchData("heartbeat", getMockHeartbeat);

  if (data && data.alive) {
    missedHeartbeats = 0;
    setHeartbeatState("alive");
    clearAlertByMessage("Server is not responding — connection lost");
  } else {
    missedHeartbeats++;
    if (missedHeartbeats >= MAX_MISSED_HEARTBEATS) {
      setHeartbeatState("dead");
      addAlert("critical", "Server is not responding — connection lost");
    } else {
      setHeartbeatState("degraded");
      addAlert("warning", "Heartbeat missed (" + missedHeartbeats + "/" + MAX_MISSED_HEARTBEATS + ") — retrying");
    }
  }

  heartbeatCountdown = HEARTBEAT_INTERVAL;
}

function updateCountdown() {
  heartbeatCountdown--;
  if (heartbeatCountdown < 0) heartbeatCountdown = 0;
  var el = document.getElementById("heartbeat-countdown");
  if (el) el.textContent = heartbeatCountdown;
}

// === Threshold Checks ===
function checkHealthAlerts(data) {
  if (!data) return;

  if (data.cpu >= CPU_THRESHOLD) {
    addAlert("critical", "CPU usage critical: " + data.cpu + "% (threshold: " + CPU_THRESHOLD + "%)");
  } else {
    clearAlertByMessage("CPU usage critical: " + data.cpu + "% (threshold: " + CPU_THRESHOLD + "%)");
  }

  if (data.memory >= MEMORY_THRESHOLD) {
    addAlert("critical", "Memory usage critical: " + data.memory + "% (threshold: " + MEMORY_THRESHOLD + "%)");
  } else {
    clearAlertByMessage("Memory usage critical: " + data.memory + "% (threshold: " + MEMORY_THRESHOLD + "%)");
  }
}

function checkConnectivityAlerts(data) {
  if (!data) return;

  if (data.activeConnections === 0) {
    addAlert("critical", "All connections dropped — 0 active connections");
  } else {
    clearAlertByMessage("All connections dropped — 0 active connections");
  }

  if (previousConnections !== null) {
    var change = Math.abs(data.activeConnections - previousConnections);
    var pctChange = previousConnections > 0 ? (change / previousConnections) * 100 : 0;
    if (pctChange > 50 && change > 10) {
      addAlert("warning", "Connection spike: " + previousConnections + " → " + data.activeConnections + " (" + Math.round(pctChange) + "% change)");
    }
  }
  previousConnections = data.activeConnections;
}

function checkLogAlerts(data) {
  if (!data || !data.logs) return;
  var failedCount = data.logs.filter(function (l) { return l.status === "failed"; }).length;
  if (failedCount > 0) {
    addAlert("warning", failedCount + " failed vendor call(s) in recent logs");
  } else {
    clearAlertByMessage(failedCount + " failed vendor call(s) in recent logs");
  }
}

// === Rendering (same as before) ===
function setTextContent(id, value) {
  var el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setBadge(id, status) {
  var el = document.getElementById(id);
  if (!el) return;
  el.textContent = status;
  el.className = "status-badge";
  if (status === "online") el.classList.add("online");
  else if (status === "degraded") el.classList.add("degraded");
  else if (status === "offline") el.classList.add("offline");
}

function setProgressBar(barId, valueId, pct) {
  var bar = document.getElementById(barId);
  var val = document.getElementById(valueId);
  if (bar) bar.style.width = pct + "%";
  if (val) val.textContent = pct + "%";

  if (bar) {
    if (pct >= 90) bar.style.background = "#ef4444";
    else if (pct >= 70) bar.style.background = "#eab308";
    else bar.style.background = "#0284c7";
  }
}

function renderHealth(data) {
  if (!data) return;
  setBadge("health-status", data.status);
  setTextContent("server-status", data.status === "online" ? "Running" : "Down");
  setTextContent("uptime", data.uptime);
  setProgressBar("cpu-bar", "cpu-usage", data.cpu);
  setProgressBar("mem-bar", "mem-usage", data.memory);
  setTextContent("disk-io", data.diskIO);
}

function renderConnectivity(data) {
  if (!data) return;
  setBadge("conn-status", data.status);
  setTextContent("active-conn", data.activeConnections);
  setTextContent("total-agents", data.totalAgents);
  setTextContent("avg-latency", data.avgLatency);
  setTextContent("packet-loss", data.packetLoss);
  setTextContent("conn-type", data.connectionType);
}

function renderLogs(data) {
  if (!data) return;
  setBadge("logs-status", data.status);
  var tbody = document.getElementById("logs-tbody");
  if (!tbody) return;
  tbody.innerHTML = "";
  data.logs.forEach(function (log) {
    var tr = document.createElement("tr");
    var statusClass = log.status === "success" ? "success" : log.status === "pending" ? "pending" : "failed";
    tr.innerHTML =
      "<td>" + log.timestamp + "</td>" +
      "<td>" + log.vendor + "</td>" +
      "<td>" + log.action + "</td>" +
      '<td><span class="log-status ' + statusClass + '">' + log.status + "</span></td>";
    tbody.appendChild(tr);
  });
}

// === Main Data Load ===
async function loadDashboard() {
  var results = await Promise.all([
    fetchData("health", getMockHealthData),
    fetchData("connectivity", getMockConnectivityData),
    fetchData("logs", getMockLogsData),
  ]);

  var health = results[0];
  var connectivity = results[1];
  var logs = results[2];

  renderHealth(health);
  renderConnectivity(connectivity);
  renderLogs(logs);

  checkHealthAlerts(health);
  checkConnectivityAlerts(connectivity);
  checkLogAlerts(logs);

  setTextContent("last-updated", new Date().toLocaleTimeString());
}

// === Start Everything ===
function startHeartbeat() {
  heartbeatPing();
  heartbeatTimerId = setInterval(function () {
    heartbeatPing();
  }, HEARTBEAT_INTERVAL * 1000);

  countdownTimerId = setInterval(updateCountdown, 1000);
}

function startDataRefresh() {
  loadDashboard();
  dataRefreshTimerId = setInterval(function () {
    loadDashboard();
  }, DATA_REFRESH_INTERVAL * 1000);
}

document.addEventListener("DOMContentLoaded", function () {
  startHeartbeat();
  startDataRefresh();

  var refreshBtn = document.getElementById("refresh-btn");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", function () {
      heartbeatPing();
      loadDashboard();
    });
  }
});
