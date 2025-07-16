const wasm = WebAssembly.compileStreaming(fetch("/wasm/playground.wasm"));

/** @param {MessageEvent} */
window.onmessage = ({ data }) => {
  if (data.type !== "analyze") throw Error("unexpected message type");

  const zigSrc = data.zigCode;

  const ptr = wasm.exports.alloc_string(zigSrc.length)
  const array = new Uint8Array(wasm.exports.memory.buffer, ptr, zigSrc.length);
  new TextEncoder("utf8").encodeInto(zigSrc, array.byteLength);


  const resultPtr = wasm.exports.analyze(ptr, array.byteLength);
  const ANALYZE_RES_SIZE = 8;
  const resultView = new DataView(wasm.exports.memory.buffer, resultPtr, ANALYZE_RES_SIZE);
  const resultStringLen = resultView.getUint32(0, true);
  const resultStringPtr = resultView.getUint32(4, true);
  const result = new TextDecoder().decode(new Uint8Array(wasm.exports.memory.buffer, resultStringPtr, resultStringLen));

  postMessage({ result });

  wasm.exports.free_string(ptr);
};




// what you want with result
