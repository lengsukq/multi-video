// Standalone Windows DirectML probe. No app DLLs or third-party GPL code.
// Usage: directml_benchmark.exe <pphumanseg.onnx>
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <dxgi1_2.h>
#include <onnxruntime_cxx_api.h>
#include <dml_provider_factory.h>

#include <array>
#include <chrono>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>
#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

static void Benchmark(const std::wstring& model, int device,
                      const std::string& name) {
  try {
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "dml-probe");
    Ort::SessionOptions options;
    options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
    options.DisableMemPattern();
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    if (device >= 0) {
      Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_DML(
          options, device));
    } else {
      options.SetIntraOpNumThreads(2);
    }
    const auto load_start = std::chrono::steady_clock::now();
    Ort::Session session(env, model.c_str(), options);
    const auto load_end = std::chrono::steady_clock::now();
    constexpr std::size_t plane = 192 * 192;
    std::vector<float> pixels(3 * plane, 0);
    const std::array<int64_t, 4> shape{1, 3, 192, 192};
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,
                                              OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(
        memory, pixels.data(), pixels.size(), shape.data(), shape.size());
    const auto allocator = Ort::AllocatorWithDefaultOptions{};
    const auto input_name = session.GetInputNameAllocated(0, allocator);
    const auto output_name = session.GetOutputNameAllocated(0, allocator);
    const char* inputs[]{input_name.get()};
    const char* outputs[]{output_name.get()};
    double elapsed_ms = 0;
    constexpr int warmups = 8;
    constexpr int samples = 50;
    for (int i = 0; i < warmups + samples; ++i) {
      const auto start = std::chrono::steady_clock::now();
      auto result = session.Run(Ort::RunOptions{nullptr}, inputs,
                                &tensor, 1, outputs, 1);
      const auto end = std::chrono::steady_clock::now();
      if (result.empty() || !result[0].IsTensor()) {
        throw std::runtime_error("No output tensor");
      }
      if (i >= warmups) {
        elapsed_ms += std::chrono::duration<double, std::milli>(
                          end - start).count();
      }
    }
    std::cout << name << " startup="
              << std::chrono::duration<double, std::milli>(
                     load_end - load_start).count()
              << "ms avg_inference=" << elapsed_ms / samples << "ms\n";
  } catch (const Ort::Exception& error) {
    std::cout << name << " unavailable: " << error.what() << "\n";
  } catch (const std::exception& error) {
    std::cout << name << " failed: " << error.what() << "\n";
  }
}

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  int size = MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, nullptr, 0);
  if (size <= 1) return 2;
  std::wstring model(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, model.data(), size);
  model.resize(size - 1);
  Benchmark(model, -1, "CPU");
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return 3;
  for (UINT i = 0; i < 8; ++i) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    DXGI_ADAPTER_DESC1 desc{};
    if (FAILED(adapter->GetDesc1(&desc))) continue;
    if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
    std::wcout << L"GPU adapter #" << i << L": " << desc.Description
               << L" (" << desc.DedicatedVideoMemory / (1024 * 1024)
               << L" MiB VRAM)\n";
    Benchmark(model, static_cast<int>(i), "DirectML adapter " +
              std::to_string(i));
  }
  return 0;
}
