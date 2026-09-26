const LABELS = {
  command: [
    ["echo", "Echo"],
    ["reverb", "Reverb"],
    ["high_pitch", "High pitch"],
    ["low_pitch", "Low pitch"],
    ["bypass", "Bypass"],
  ],
  unknown: [["unknown", "Unknown / noise"]],
  silence: [["silence", "Silence"]],
  calibration_noise: [["calibration_noise", "Calibration noise"]],
};

const TARGETS = [
  ["echo", "Echo", 100],
  ["reverb", "Reverb", 100],
  ["high_pitch", "High pitch", 100],
  ["low_pitch", "Low pitch", 100],
  ["bypass", "Bypass", 100],
  ["unknown", "Unknown / noise", 250],
  ["silence", "Silence", 125],
  ["calibration_noise", "Calibration noise", 125],
];

const state = {
  samples: [],
  mainFiles: [],
  noiseFile: null,
  recording: null,
  mainRecordedUrl: null,
  noiseRecordedUrl: null,
};

const $ = (selector) => document.querySelector(selector);
const sampleType = $("#sample-type");
const label = $("#label");
const mainFile = $("#main-file");
const noiseFile = $("#noise-file");
const form = $("#sample-form");

function pretty(value) {
  return String(value || "—").replaceAll("_", " ").replace(/\b\w/g, (char) => char.toUpperCase());
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;",
  }[char]));
}

function toast(message) {
  const element = $("#toast");
  element.textContent = message;
  element.classList.add("visible");
  window.clearTimeout(toast.timer);
  toast.timer = window.setTimeout(() => element.classList.remove("visible"), 2600);
}

function setMessage(message, error = false) {
  const element = $("#form-message");
  element.textContent = message;
  element.classList.toggle("error", error);
}

function updateLabels() {
  label.innerHTML = LABELS[sampleType.value]
    .map(([value, text]) => `<option value="${value}">${text}</option>`)
    .join("");
  const command = sampleType.value === "command";
  $("#noise-profile-card").style.opacity = command ? "1" : ".58";
}

function updateFileState(kind) {
  const files = kind === "main" ? state.mainFiles : state.noiseFile ? [state.noiseFile] : [];
  const stateElement = $(`#${kind}-state`);
  const preview = $(`#${kind}-preview`);
  const oldUrlKey = kind === "main" ? "mainRecordedUrl" : "noiseRecordedUrl";
  if (!files.length) {
    stateElement.textContent = kind === "main" ? "No audio" : "Optional";
    stateElement.classList.remove("ready");
    preview.hidden = true;
    preview.removeAttribute("src");
    return;
  }
  stateElement.textContent = files.length === 1 ? files[0].name : `${files.length} files`;
  stateElement.classList.add("ready");
  if (files.length === 1) {
    if (state[oldUrlKey]) URL.revokeObjectURL(state[oldUrlKey]);
    state[oldUrlKey] = URL.createObjectURL(files[0]);
    preview.src = state[oldUrlKey];
    preview.hidden = false;
  } else {
    preview.hidden = true;
  }
}

mainFile.addEventListener("change", () => {
  state.mainFiles = [...mainFile.files];
  updateFileState("main");
});

noiseFile.addEventListener("change", () => {
  state.noiseFile = noiseFile.files[0] || null;
  updateFileState("noise");
});

$("#clear-main").addEventListener("click", () => {
  mainFile.value = "";
  state.mainFiles = [];
  updateFileState("main");
});

$("#clear-noise").addEventListener("click", () => {
  noiseFile.value = "";
  state.noiseFile = null;
  updateFileState("noise");
});

sampleType.addEventListener("change", updateLabels);

async function recordWav(target) {
  const button = target === "main" ? $("#record-main") : $("#record-noise");
  if (state.recording) {
    if (state.recording.target !== target) {
      toast("Stop the current recording first.");
      return;
    }
    const result = await state.recording.stop();
    state.recording = null;
    button.textContent = target === "main" ? "Record main audio" : "Record noise";
    button.classList.remove("recording");
    const filename = `${target}_${new Date().toISOString().replaceAll(":", "-")}.wav`;
    const file = new File([result.blob], filename, { type: "audio/wav" });
    if (target === "main") state.mainFiles = [file];
    else state.noiseFile = file;
    updateFileState(target);
    toast(`Recorded ${(result.frames / result.sampleRate).toFixed(1)} seconds at ${result.sampleRate} Hz.`);
    return;
  }

  try {
    const recorder = await createWavRecorder(target);
    state.recording = recorder;
    button.textContent = "Stop recording";
    button.classList.add("recording");
    setMessage("Recording from the laptop microphone…");
  } catch (error) {
    setMessage(`Microphone unavailable: ${error.message}`, true);
  }
}

async function createWavRecorder(target) {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
  });
  const context = new AudioContext({ sampleRate: 48000 });
  const source = context.createMediaStreamSource(stream);
  const processor = context.createScriptProcessor(4096, 1, 1);
  const mute = context.createGain();
  mute.gain.value = 0;
  const chunks = [];
  let frames = 0;
  processor.onaudioprocess = (event) => {
    const channel = event.inputBuffer.getChannelData(0);
    chunks.push(new Float32Array(channel));
    frames += channel.length;
  };
  source.connect(processor);
  processor.connect(mute);
  mute.connect(context.destination);

  return {
    target,
    stop: async () => {
      processor.disconnect();
      source.disconnect();
      mute.disconnect();
      stream.getTracks().forEach((track) => track.stop());
      await context.close();
      const samples = new Float32Array(frames);
      let offset = 0;
      chunks.forEach((chunk) => { samples.set(chunk, offset); offset += chunk.length; });
      return { blob: encodeWav(samples, context.sampleRate), frames, sampleRate: context.sampleRate };
    },
  };
}

function encodeWav(samples, sampleRate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const write = (offset, text) => [...text].forEach((char, index) => view.setUint8(offset + index, char.charCodeAt(0)));
  write(0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  write(8, "WAVE");
  write(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  write(36, "data");
  view.setUint32(40, samples.length * 2, true);
  let offset = 44;
  for (const sample of samples) {
    const clipped = Math.max(-1, Math.min(1, sample));
    view.setInt16(offset, clipped < 0 ? clipped * 0x8000 : clipped * 0x7fff, true);
    offset += 2;
  }
  return new Blob([view], { type: "audio/wav" });
}

$("#record-main").addEventListener("click", () => recordWav("main"));
$("#record-noise").addEventListener("click", () => recordWav("noise"));

function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!state.mainFiles.length) {
    setMessage("Choose or record the main audio first.", true);
    return;
  }
  if (!form.reportValidity()) return;

  const submit = form.querySelector('button[type="submit"]');
  submit.disabled = true;
  submit.textContent = "Saving…";
  setMessage(`Saving ${state.mainFiles.length} sample${state.mainFiles.length > 1 ? "s" : ""}…`);
  try {
    const noiseData = state.noiseFile ? await fileToDataUrl(state.noiseFile) : null;
    for (let index = 0; index < state.mainFiles.length; index += 1) {
      const file = state.mainFiles[index];
      const payload = {
        sampleType: sampleType.value,
        label: label.value,
        speaker: $("#speaker").value,
        session: $("#session").value,
        environment: $("#environment").value,
        distance: $("#distance").value,
        split: $("#split").value,
        notes: $("#notes").value,
        audio: { name: file.name, data: await fileToDataUrl(file) },
        noiseProfile: noiseData ? { name: state.noiseFile.name, data: noiseData } : null,
      };
      const response = await fetch("/api/samples", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || "Upload failed");
      setMessage(`Saved ${index + 1} of ${state.mainFiles.length}…`);
    }
    mainFile.value = "";
    noiseFile.value = "";
    state.mainFiles = [];
    state.noiseFile = null;
    updateFileState("main");
    updateFileState("noise");
    $("#notes").value = "";
    await loadSamples();
    setMessage("Saved locally. Add another condition or speaker.");
    toast("Training sample saved.");
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    submit.disabled = false;
    submit.textContent = "Save sample";
  }
});

async function loadSamples() {
  try {
    const response = await fetch("/api/samples", { cache: "no-store" });
    if (!response.ok) throw new Error("Could not load manifest");
    const data = await response.json();
    state.samples = data.samples || [];
    renderAll();
  } catch (error) {
    toast(error.message);
  }
}

function renderAll() {
  const commands = state.samples.filter((sample) => sample.sample_type === "command");
  const negatives = state.samples.filter((sample) => ["unknown", "silence"].includes(sample.sample_type));
  const paired = commands.filter((sample) => sample.noise_profile_path).length;
  $("#metric-total").textContent = state.samples.length.toLocaleString();
  $("#metric-command").textContent = commands.length.toLocaleString();
  $("#metric-negative").textContent = negatives.length.toLocaleString();
  $("#metric-paired").textContent = commands.length ? `${Math.round((paired / commands.length) * 100)}%` : "0%";
  renderCoverage();
  renderFilters();
  renderTable();
}

function renderCoverage() {
  const counts = Object.fromEntries(TARGETS.map(([key]) => [key, state.samples.filter((sample) => sample.label === key).length]));
  $("#coverage-grid").innerHTML = TARGETS.map(([key, name, target]) => {
    const count = counts[key];
    const percent = Math.min(100, Math.round((count / target) * 100));
    return `<article class="coverage-card">
      <header><h3>${name}</h3><span>${percent}%</span></header>
      <div class="progress-track"><i style="width:${percent}%"></i></div>
      <footer><span>${count} collected</span><span>${target} target</span></footer>
    </article>`;
  }).join("");
}

function renderFilters() {
  const select = $("#filter-label");
  const current = select.value;
  select.innerHTML = '<option value="all">All labels</option>' + TARGETS
    .map(([key, name]) => `<option value="${key}">${name}</option>`).join("");
  if ([...select.options].some((option) => option.value === current)) select.value = current;
}

function renderTable() {
  const search = $("#search").value.trim().toLowerCase();
  const selectedLabel = $("#filter-label").value;
  const filtered = [...state.samples].reverse().filter((sample) => {
    if (selectedLabel !== "all" && sample.label !== selectedLabel) return false;
    if (!search) return true;
    return [sample.label, sample.speaker, sample.session, sample.environment, sample.source_filename]
      .join(" ").toLowerCase().includes(search);
  });
  const body = $("#sample-table");
  body.innerHTML = filtered.map((sample) => `<tr>
    <td><strong>${escapeHtml(sample.source_filename)}</strong><small>${new Date(sample.created_at).toLocaleString()}</small></td>
    <td><span class="label-chip">${escapeHtml(pretty(sample.label))}</span>${sample.noise_profile_path ? "<small>paired noise</small>" : ""}</td>
    <td><strong>${escapeHtml(sample.speaker || "—")}</strong><small>${escapeHtml(sample.session || "—")}</small></td>
    <td>${escapeHtml(pretty(sample.environment))}<small>${escapeHtml(pretty(sample.distance))}</small></td>
    <td><span class="split-chip">${escapeHtml(pretty(sample.split))}</span></td>
    <td><audio controls preload="none" src="/api/audio/${encodeURIComponent(sample.id)}"></audio></td>
    <td><button class="delete-button" data-id="${escapeHtml(sample.id)}" type="button">Delete</button></td>
  </tr>`).join("");
  $("#empty-state").hidden = filtered.length > 0;
  body.querySelectorAll(".delete-button").forEach((button) => button.addEventListener("click", () => deleteSample(button.dataset.id)));
}

async function deleteSample(id) {
  if (!window.confirm("Delete this sample and its paired noise file?")) return;
  const response = await fetch(`/api/samples/${encodeURIComponent(id)}`, { method: "DELETE" });
  const result = await response.json();
  if (!response.ok) {
    toast(result.error || "Delete failed");
    return;
  }
  await loadSamples();
  toast("Sample deleted.");
}

$("#search").addEventListener("input", renderTable);
$("#filter-label").addEventListener("change", renderTable);

updateLabels();
updateFileState("main");
updateFileState("noise");
loadSamples();
