// === Configuration ===
// Replace with your actual server endpoint when ready
const API_BASE = null; // e.g. "http://192.168.1.100:8080/api"

// === Mock Data (used when API_BASE is null) ===
function getMockHealthData() {
  return {
    status: "online",
    uptime: "14d 7h 32m",
    cpu: 42,
    memory: 67,
    diskIO: "128 MB/s",
  };
}

function getMockConnectivityData() {
  return {
    status: "online",
    activeConnections: 184,
    totalAgents: 312,
    avgLatency: "23ms",
    packetLoss: "0.02%",
    connectionType: "Non Site-to-Site",
  };
}

function getMockLogsData() {
  return {
    status: "online",
    logs: [
      { timestamp: "2026-05-11 14:32:01", vendor: "Vendor A — Cisco ASA", action: "Call Activation", status: "success" },
      { timestamp: "2026-05-11 14:28:44", vendor: "Vendor B — Palo Alto", action: "Health Probe", status: "success" },
      { timestamp: "2026-05-11 14:25:12", vendor: "Vendor C — Fortinet", action: "Tunnel Re-key", status: "pending" },
      { timestamp: "2026-05-11 14:20:03", vendor: "Vendor A — Cisco ASA", action: "Log Rotation", status: "success" },
      { timestamp: "2026-05-11 14:15:58", vendor: "Vendor D — Check Point", action: "Call Activation", status: "failed" },
      { timestamp: "2026-05-11 14:10:30", vendor: "Vendor B — Palo Alto", action: "Connectivity Check", status: "success" },
    ],
  };
}

// === Data Fetching ===
async function fetchData(endpoint, mockFn) {
  if (!API_BASE) {
    return mockFn();
  }
  try {
    const res = await fetch(`${API_BASE}/${endpoint}`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return await res.json();
  } catch (err) {
    console.error(`Fetch failed for ${endpoint}:`, err);
    return null;
  }
}

// === Rendering ===
function setTextContent(id, value) {
  const el = document.getElementById(id);
  if (el) el.textContent = value;
}

function setBadge(id, status) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = status;
  el.className = "status-badge";
  if (status === "online") el.classList.add("online");
  else if (status === "degraded") el.classList.add("degraded");
  else if (status === "offline") el.classList.add("offline");
}

function setProgressBar(barId, valueId, pct) {
  const bar = document.getElementById(barId);
  const val = document.getElementById(valueId);
  if (bar) bar.style.width = pct + "%";
  if (val) val.textContent = pct + "%";
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
  const tbody = document.getElementById("logs-tbody");
  if (!tbody) return;
  tbody.innerHTML = "";
  data.logs.forEach(function (log) {
    const tr = document.createElement("tr");
    const statusClass = log.status === "success" ? "success" : log.status === "pending" ? "pending" : "failed";
    tr.innerHTML =
      "<td>" + log.timestamp + "</td>" +
      "<td>" + log.vendor + "</td>" +
      "<td>" + log.action + "</td>" +
      '<td><span class="log-status ' + statusClass + '">' + log.status + "</span></td>";
    tbody.appendChild(tr);
  });
}

// === Main ===
async function loadDashboard() {
  const [health, connectivity, logs] = await Promise.all([
    fetchData("health", getMockHealthData),
    fetchData("connectivity", getMockConnectivityData),
    fetchData("logs", getMockLogsData),
  ]);

  renderHealth(health);
  renderConnectivity(connectivity);
  renderLogs(logs);

  setTextContent("last-updated", new Date().toLocaleTimeString());
}

document.addEventListener("DOMContentLoaded", function () {
  loadDashboard();

  var refreshBtn = document.getElementById("refresh-btn");
  if (refreshBtn) {
    refreshBtn.addEventListener("click", function () {
      loadDashboard();
    });
  }
});
