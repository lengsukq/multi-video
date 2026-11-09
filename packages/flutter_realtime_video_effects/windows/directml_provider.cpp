// This is intentionally a separate translation unit: DirectML's public
// header defines global enum values that conflict with Media Foundation.
// Only this Windows plugin translation unit includes dml_provider_factory.h.
#include <onnxruntime_cxx_api.h>
#include <dml_provider_factory.h>

void AppendDirectMlProvider(Ort::SessionOptions& options, int adapter_id) {
  Ort::ThrowOnError(
      OrtSessionOptionsAppendExecutionProvider_DML(options, adapter_id));
}
