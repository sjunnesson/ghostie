// This target exists only to expose the vendored ONNX Runtime C API
// declarations (types + the OrtApi function-pointer table) to Swift.
// Nothing links against onnxruntime at build time — the dylib is dlopen'd
// at runtime by ORTRuntime.swift, so builds and the .dmg stay dependency-free
// and the ONNX LID activates only on machines that installed the runtime.
