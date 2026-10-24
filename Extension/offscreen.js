const ANYCAST = "ws://127.0.0.1:47801/tab";
let recorder = null;
let socket = null;
let stream = null;

function notify(type) {
  chrome.runtime.sendMessage({ target: "background", type });
}

function stop() {
  if (recorder && recorder.state !== "inactive") recorder.stop();
  stream?.getTracks().forEach((track) => track.stop());
  if (socket && socket.readyState <= 1) socket.close();
  recorder = socket = stream = null;
  notify("stopped");
}

async function start(streamId, title) {
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: streamId } },
      video: {
        mandatory: {
          chromeMediaSource: "tab",
          chromeMediaSourceId: streamId,
          maxWidth: 1920,
          maxHeight: 1080,
          maxFrameRate: 30,
        },
      },
    });
  } catch (error) {
    console.error(error);
    return notify("error");
  }

  // The tab is muted while captured, so its sound only plays on the TV.
  socket = new WebSocket(ANYCAST);
  socket.binaryType = "arraybuffer";
  socket.onerror = () => { stop(); notify("error"); };
  socket.onclose = () => { if (recorder) stop(); };
  socket.onopen = () => {
    const types = ["video/webm;codecs=h264,opus", "video/webm;codecs=vp9,opus", "video/webm"];
    const mimeType = types.find((type) => MediaRecorder.isTypeSupported(type));
    socket.send(JSON.stringify({ title, mimeType }));
    recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: 12_000_000, audioBitsPerSecond: 256_000 });
    recorder.ondataavailable = async (event) => {
      if (event.data.size > 0 && socket?.readyState === 1) socket.send(await event.data.arrayBuffer());
    };
    recorder.onstop = () => stop();
    recorder.start(100);
  };
  stream.getVideoTracks()[0].onended = stop;
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.target !== "offscreen") return;
  if (message.type === "start") start(message.streamId, message.title);
  if (message.type === "stop") stop();
});
