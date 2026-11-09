#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "processed_video_compositor.h"

#if defined(REALTIME_VIDEO_EFFECTS_ONNX)
#include <onnxruntime_cxx_api.h>
#endif
#if defined(REALTIME_VIDEO_EFFECTS_DIRECTML)
#include <dxgi1_2.h>
#include <wrl/client.h>
// Keep DirectML's "Default" enum out of the Media Foundation translation
// unit. It collides with a global Windows SDK enumerator on MSVC.
void AppendDirectMlProvider(Ort::SessionOptions& options, int adapter_id);
#endif

namespace realtime_video_effects {

// PPHumanSeg (OpenCV Zoo, Apache-2.0), 192x192 NCHW float RGB.
// Inference is not available without both ONNX Runtime and an on-disk model.
// In that case this class returns false; it must never generate a fake mask.
class PersonSegmenter final {
 public:
  static constexpr int kWidth = 192;
  static constexpr int kHeight = 192;
  ~PersonSegmenter() {
#if defined(REALTIME_VIDEO_EFFECTS_DIRECTML)
    if (gpu_state_) gpu_state_->cancelled.store(true);
#endif
  }

  bool Open(const std::wstring& model) {
#if defined(REALTIME_VIDEO_EFFECTS_ONNX)
    try {
      Ort::SessionOptions options;
      options.SetIntraOpNumThreads(2);
      options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
      session_ = std::make_unique<Ort::Session>(environment_, model.c_str(),
                                               options);
      Ort::AllocatorWithDefaultOptions allocator;
      const auto input = session_->GetInputNameAllocated(0, allocator);
      const auto output = session_->GetOutputNameAllocated(0, allocator);
      input_name_ = input.get() ? input.get() : "";
      output_name_ = output.get() ? output.get() : "";
      if (input_name_.empty() || output_name_.empty()) return false;
#if defined(REALTIME_VIDEO_EFFECTS_DIRECTML)
      // Never initialize a GPU session on Flutter's platform thread. Some
      // integrated graphics drivers need tens of seconds on first use.
      gpu_state_ = std::make_shared<GpuState>();
      auto state = gpu_state_;
      std::thread([state, model]() { InitializeGpu(state, model); }).detach();
#endif
      return true;
    } catch (const std::exception&) {
      session_.reset();
      return false;
    }
#else
    (void)model;
    return false;
#endif
  }

  bool Ready() const {
#if defined(REALTIME_VIDEO_EFFECTS_ONNX)
    return session_ != nullptr;
#else
    return false;
#endif
  }

  bool Infer(const realtime_processed_video::Frame& frame,
             realtime_processed_video::PersonMask* mask) {
#if defined(REALTIME_VIDEO_EFFECTS_ONNX)
    if (!Ready() || !mask || !frame.IsValid()) return false;
    constexpr std::size_t plane = kWidth * kHeight;
    std::vector<float> input(plane * 3);
    // Match OpenCV Zoo's cv::resize(..., INTER_LINEAR) preprocessing.
    // Nearest-neighbour downsampling aliases hair and face boundaries badly
    // at the model's 192x192 resolution, especially from 720p webcams.
    constexpr float kRgbScale = 2.0f / 255.0f;
    for (int y = 0; y < kHeight; ++y) {
      const float fy = std::clamp(
          (static_cast<float>(y) + 0.5f) * frame.height / kHeight - 0.5f,
          0.0f, static_cast<float>(frame.height - 1));
      const auto y0 = static_cast<std::uint32_t>(fy);
      const auto y1 = std::min(y0 + 1, frame.height - 1);
      const float wy = fy - y0;
      const auto* row0 = frame.pixels->data() +
          static_cast<std::size_t>(y0) * frame.stride;
      const auto* row1 = frame.pixels->data() +
          static_cast<std::size_t>(y1) * frame.stride;
      for (int x = 0; x < kWidth; ++x) {
        const float fx = std::clamp(
            (static_cast<float>(x) + 0.5f) * frame.width / kWidth - 0.5f,
            0.0f, static_cast<float>(frame.width - 1));
        const auto x0 = static_cast<std::uint32_t>(fx);
        const auto x1 = std::min(x0 + 1, frame.width - 1);
        const float wx = fx - x0;
        const auto at = static_cast<std::size_t>(y) * kWidth + x;
        // Source memory is BGRA; the model expects planar RGB.
        for (int channel = 0; channel < 3; ++channel) {
          const int c = 2 - channel;
          const float top = row0[x0 * 4 + c] +
              (row0[x1 * 4 + c] - row0[x0 * 4 + c]) * wx;
          const float bottom = row1[x0 * 4 + c] +
              (row1[x1 * 4 + c] - row1[x0 * 4 + c]) * wx;
          input[static_cast<std::size_t>(channel) * plane + at] =
              (top + (bottom - top) * wy) * kRgbScale - 1.0f;
        }
      }
    }
    try {
      const std::array<std::int64_t, 4> shape{1, 3, kHeight, kWidth};
      auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
      auto tensor = Ort::Value::CreateTensor<float>(
          memory, input.data(), input.size(), shape.data(), shape.size());
      const auto run = [&](Ort::Session* session, const std::string& in,
                           const std::string& out) {
        const char* inputs[]{in.c_str()};
        const char* outputs[]{out.c_str()};
        auto result = session->Run(Ort::RunOptions{nullptr}, inputs,
                                   &tensor, 1, outputs, 1);
        if (result.size() != 1 || !result.front().IsTensor())
          throw std::runtime_error("Invalid segmentation output");
        return std::move(result.front());
      };
      Ort::Value output{nullptr};
      bool used_gpu = false;
#if defined(REALTIME_VIDEO_EFFECTS_DIRECTML)
      std::shared_ptr<GpuModel> gpu;
      auto state = gpu_state_;
      if (state && !state->disabled.load()) {
        std::lock_guard<std::mutex> lock(state->mutex);
        gpu = state->model;
      }
      if (gpu) {
        try {
          output = run(gpu->session.get(), gpu->input_name, gpu->output_name);
          used_gpu = true;
        } catch (const std::exception&) {
          // A GPU device can disappear after initialization (driver reset,
          // docking change, RDP session). Fail over immediately to CPU.
          state->disabled.store(true);
        }
      }
#endif
      if (!used_gpu) output = run(session_.get(), input_name_, output_name_);
      const auto dimensions = output.GetTensorTypeAndShapeInfo().GetShape();
      // Reject unknown layouts or labels. Model output is [1, 2, 192, 192].
      if (dimensions.size() != 4 || dimensions[0] != 1 ||
          dimensions[1] != 2 || dimensions[2] != kHeight ||
          dimensions[3] != kWidth) return false;
      // This shipped PPHumanSeg ONNX model ends with Softmax. The two
      // output planes already contain probabilities summing to 1.
      // NEVER apply Softmax/sigmoid again: doing so constrains person alpha
      // to [0.269, 0.731], making even fully detected people translucent
      // and visibly blurred against the replaced background.
      const float* probabilities = output.GetTensorData<float>();
      realtime_processed_video::PersonMask next;
      next.width = kWidth;
      next.height = kHeight;
      next.alpha.resize(plane);
      for (std::size_t i = 0; i < plane; ++i) {
        const float background = probabilities[i];
        const float foreground = probabilities[plane + i];
        if (!std::isfinite(background) || !std::isfinite(foreground) ||
            background < -0.001f || background > 1.001f ||
            foreground < -0.001f || foreground > 1.001f ||
            std::abs(background + foreground - 1.0f) > 0.02f)
          return false;
        // Channel 1 is the foreground person probability. Preserve its
        // full 0..1 range so the person's interior remains perfectly sharp.
        next.alpha[i] = std::clamp(foreground, 0.0f, 1.0f);
      }
      *mask = std::move(next);
      return true;
    } catch (const Ort::Exception&) {
      return false;
    }
#else
    (void)frame;
    (void)mask;
    return false;
#endif
  }

 private:
#if defined(REALTIME_VIDEO_EFFECTS_DIRECTML)
  // GPU initialization is self-contained. A detached driver initialization
  // may outlive the capture source without accessing destroyed Source state.
  struct GpuModel {
    Ort::Env environment{ORT_LOGGING_LEVEL_WARNING, "video_effects_dml"};
    std::unique_ptr<Ort::Session> session;
    std::string input_name, output_name;
  };
  struct GpuState {
    std::mutex mutex;
    std::shared_ptr<GpuModel> model;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> disabled{false};
  };

  static double Measure(Ort::Session& session) {
    const std::array<std::int64_t, 4> shape{1, 3, kHeight, kWidth};
    std::vector<float> input(3 * kWidth * kHeight, 0.12f);
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    auto tensor = Ort::Value::CreateTensor<float>(
        memory, input.data(), input.size(), shape.data(), shape.size());
    Ort::AllocatorWithDefaultOptions allocator;
    const auto in = session.GetInputNameAllocated(0, allocator);
    const auto out = session.GetOutputNameAllocated(0, allocator);
    const char* names_in[]{in.get()};
    const char* names_out[]{out.get()};
    double total = 0;
    constexpr int kWarmup = 4, kSamples = 18;
    for (int i = 0; i < kWarmup + kSamples; ++i) {
      const auto start = std::chrono::steady_clock::now();
      auto result = session.Run(Ort::RunOptions{nullptr}, names_in, &tensor,
                                1, names_out, 1);
      const auto end = std::chrono::steady_clock::now();
      if (result.size() != 1 || !result[0].IsTensor())
        throw std::runtime_error("DirectML returned invalid tensor");
      if (i >= kWarmup)
        total += std::chrono::duration<double, std::milli>(end - start).count();
    }
    return total / kSamples;
  }

  static void InitializeGpu(const std::shared_ptr<GpuState>& state,
                            const std::wstring& model) {
    try {
      // Compare against the real CPU execution provider on THIS machine.
      auto cpu = std::make_shared<GpuModel>();
      Ort::SessionOptions cpu_options;
      cpu_options.SetIntraOpNumThreads(2);
      cpu_options.SetGraphOptimizationLevel(
          GraphOptimizationLevel::ORT_ENABLE_ALL);
      cpu->session = std::make_unique<Ort::Session>(
          cpu->environment, model.c_str(), cpu_options);
      const auto cpu_ms = Measure(*cpu->session);
      if (state->cancelled.load()) return;

      Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
      if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return;
      struct Adapter {
        int index;
        std::size_t dedicated;
      };
      std::vector<Adapter> adapters;
      std::set<std::pair<LONG, DWORD>> seen;
      for (UINT i = 0; i < 16; ++i) {
        Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 desc{};
        if (FAILED(adapter->GetDesc1(&desc)) ||
            (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) continue;
        if (!seen.insert({desc.AdapterLuid.HighPart,
                          desc.AdapterLuid.LowPart}).second) continue;
        adapters.push_back({static_cast<int>(i),
                            static_cast<std::size_t>(desc.DedicatedVideoMemory)});
      }
      // Dedicated GPUs usually have a much smaller model startup penalty.
      std::stable_sort(adapters.begin(), adapters.end(),
          [](const Adapter& a, const Adapter& b) {
            return a.dedicated > b.dedicated;
          });

      for (const auto& adapter : adapters) {
        if (state->cancelled.load()) return;
        try {
          auto gpu = std::make_shared<GpuModel>();
          Ort::SessionOptions options;
          options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
          options.DisableMemPattern();  // Required by DirectML EP.
          options.SetGraphOptimizationLevel(
              GraphOptimizationLevel::ORT_ENABLE_ALL);
          AppendDirectMlProvider(options, adapter.index);
          gpu->session = std::make_unique<Ort::Session>(
              gpu->environment, model.c_str(), options);
          const auto gpu_ms = Measure(*gpu->session);
          // Do not use a GPU which is slower than the CPU once upload and
          // readback overhead have been included in actual Run latency.
          if (gpu_ms >= cpu_ms * 0.92 || state->cancelled.load()) continue;
          Ort::AllocatorWithDefaultOptions allocator;
          auto in = gpu->session->GetInputNameAllocated(0, allocator);
          auto out = gpu->session->GetOutputNameAllocated(0, allocator);
          gpu->input_name = in.get() ? in.get() : "";
          gpu->output_name = out.get() ? out.get() : "";
          if (gpu->input_name.empty() || gpu->output_name.empty()) continue;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->cancelled.load()) state->model = std::move(gpu);
          }
          return;
        } catch (const std::exception&) {
          // Driver, adapter and unsupported-op errors are non-fatal.
        }
      }
    } catch (const std::exception&) {
      // CPU session is already ready and never depends on GPU success.
    }
  }

  std::shared_ptr<GpuState> gpu_state_;
#endif
#if defined(REALTIME_VIDEO_EFFECTS_ONNX)
  Ort::Env environment_{ORT_LOGGING_LEVEL_WARNING, "flutter_video_effects"};
  std::unique_ptr<Ort::Session> session_;
  std::string input_name_;
  std::string output_name_;
#endif
};

}  // namespace realtime_video_effects
