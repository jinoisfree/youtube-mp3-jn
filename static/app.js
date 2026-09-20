const form = document.querySelector("#converter");
const urlInput = document.querySelector("#url");
const rightsInput = document.querySelector("#rights");
const submitButton = document.querySelector("#submit");
const statusBox = document.querySelector("#status");
const historyToggle = document.querySelector("#history-toggle");
const historyPanel = document.querySelector("#history-panel");
const historyList = document.querySelector("#history-list");
const historyEmpty = document.querySelector("#history-empty");

function showStatus(content, isError = false) {
  statusBox.hidden = false;
  statusBox.classList.toggle("error", isError);
  statusBox.replaceChildren(content);
}

async function loadHistory() {
  historyList.replaceChildren();
  historyEmpty.hidden = false;
  historyEmpty.textContent = "불러오는 중…";

  try {
    const response = await fetch("/api/history", { cache: "no-store" });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "목록을 불러오지 못했습니다.");

    const items = Array.isArray(result.items) ? result.items.slice(0, 5) : [];
    historyEmpty.hidden = items.length > 0;
    historyEmpty.textContent = "저장된 MP3가 없습니다.";
    for (const item of items) {
      const row = document.createElement("li");
      const link = document.createElement("a");
      link.href = item.downloadUrl;
      link.download = item.filename;
      link.textContent = item.filename;
      row.append(link);
      historyList.append(row);
    }
  } catch (error) {
    historyEmpty.hidden = false;
    historyEmpty.textContent = error.message;
  }
}

historyToggle.addEventListener("click", async () => {
  const willOpen = historyPanel.hidden;
  historyPanel.hidden = !willOpen;
  historyToggle.setAttribute("aria-expanded", String(willOpen));
  if (willOpen) await loadHistory();
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!form.reportValidity()) return;

  submitButton.disabled = true;
  submitButton.textContent = "변환 중…";
  showStatus(document.createTextNode("영상을 확인하고 오디오를 변환하고 있습니다. 창을 닫지 마세요."));

  try {
    const response = await fetch("/api/convert", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url: urlInput.value, rightsConfirmed: rightsInput.checked }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "변환 요청에 실패했습니다.");

    const link = document.createElement("a");
    link.href = result.downloadUrl;
    link.download = result.filename;
    link.textContent = `${result.filename} 다운로드`;
    showStatus(link);
    if (!historyPanel.hidden) await loadHistory();
  } catch (error) {
    showStatus(document.createTextNode(error.message), true);
  } finally {
    submitButton.disabled = false;
    submitButton.textContent = "MP3 변환";
  }
});
