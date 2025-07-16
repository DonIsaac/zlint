// @ts-check

// TODO: can't do this efficient one liner cuz docusaurus is serving locally as HTML mimetype
//const wasmPromise = WebAssembly.instantiateStreaming(fetch("/zlint/wasm/playground.wasm"));
const wasmPromise = (async () => {
  const wasmResp = await fetch("/zlint/wasm/playground.wasm");
  const wasmBytes = await wasmResp.arrayBuffer();
  const wasm = WebAssembly.instantiate(wasmBytes);
  return wasm;
})();

/** @param {MessageEvent} ev */
globalThis.onmessage = async (ev) => {
  const wasm = await wasmPromise;
  const { data } = ev;
  if (data.type !== "analyze") throw Error("unexpected message type");

  const zigSrc = data.zigCode;

  const wexp = wasm.instance.exports;
  const ptr = wexp.alloc_string(zigSrc.length)
  const array = new Uint8Array(wexp.memory.buffer, ptr, zigSrc.length);
  new TextEncoder().encodeInto(zigSrc, array);

  const resultPtr = wexp.analyze(ptr, array.byteLength);
  const resultView = new DataView(wexp.memory.buffer, resultPtr, 4);
  const resultStringLen = resultView.getUint32(0, true);
  const resultStringPtr = resultPtr + 4;
  const result = new TextDecoder().decode(new Uint8Array(wexp.memory.buffer, resultStringPtr, resultStringLen));

  postMessage({ result });

  wexp.free_string(ptr);
};




// what you want with result
