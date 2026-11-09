#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>

#include "d3d11_compositor_shaders.h"
#include "processed_video_compositor.h"
#include "video_effects_pixel_pool.h"

namespace realtime_video_effects {

struct WindowsBlurPlan {
  std::uint32_t radius;
  std::uint32_t passes;
};

// Input radius uses the provider-neutral low/medium/high values 8/16/24.
// More passes at quarter resolution give a substantially softer bokeh-like
// background without blurring the full-res foreground or adding textures.
inline WindowsBlurPlan ChooseWindowsBlurPlan(int radius,
                                             std::uint32_t scale) {
  const auto safe_scale = std::max<std::uint32_t>(scale, 1);
  const auto base = static_cast<std::uint32_t>(
      std::clamp((std::clamp(radius, 1, 32) + static_cast<int>(safe_scale) - 1) /
                     static_cast<int>(safe_scale), 1, 12));
  if (radius <= 8) return {base, 1};
  if (radius <= 16) return {std::min(base * 2u, 12u), 2};
  return {std::min(base * 2u, 12u), 3};
}

// A vendor-neutral Direct3D 11 compositor. Runs entirely on Source's
// composition worker, never on the camera/Flutter/RTC callback thread.
// CPU BGRA is uploaded once, blur/mask/blend run on the GPU, and one BGRA
// frame is read back for the existing cross-provider FrameHub ABI.
//
// The class caches its textures, shaders and replacement image. When D3D11
// is unavailable or slower than CPU it falls back transparently.
class WindowsGpuCompositor final {
 public:
  // Call only from the Source composition worker or under its compositor
  // mutex. Rendering and destruction never race across threads.
  void Release() {
    context_.Reset();
    readback_.Reset();
    camera_.Clear();
    mask_.Clear();
    output_.Clear();
    blur_horizontal_.Clear();
    blur_vertical_.Clear();
    replacement_.Clear();
    horizontal_.Reset();
    horizontal_reduced_.Reset();
    vertical_.Reset();
    composite_.Reset();
    parameters_.Reset();
    device_.Reset();
    cached_replacement_.reset();
    output_buffers_.Trim();
    width_ = height_ = mask_width_ = mask_height_ = 0;
    initialized_ = disabled_ = false;
    samples_ = steady_samples_ = 0;
    gpu_total_ms_ = cpu_baseline_ms_ = moving_gpu_ms_ = 0;
  }

  bool Compose(
      const realtime_processed_video::Frame& camera,
      const realtime_processed_video::PersonMask& mask,
      const std::shared_ptr<const realtime_processed_video::BackgroundSettings>&
          settings,
      realtime_processed_video::Frame* output) {
    using namespace realtime_processed_video;
    if (disabled_ || !settings || !output || !camera.IsValid() ||
        !mask.Valid() || settings->mode == BackgroundMode::none ||
        camera.width > 1920 || camera.height > 1080 ||
        mask.width > 4096 || mask.height > 4096)
      return false;
    if (!initialized_) {
      initialized_ = true;
      if (!Initialize()) {
        disabled_ = true;
        return false;
      }
    }
    if (!EnsureSize(camera.width, camera.height, mask.width, mask.height) ||
        !Upload(camera, mask, settings)) {
      disabled_ = true;
      return false;
    }
    const auto started = std::chrono::steady_clock::now();
    if (!DispatchFrame(camera, *settings) || !Readback(camera, settings, output)) {
      disabled_ = true;
      return false;
    }
    const auto finished = std::chrono::steady_clock::now();
    const double gpu_ms =
        std::chrono::duration<double, std::milli>(finished - started).count();
    if (samples_ < 8) {
      gpu_total_ms_ += gpu_ms;
      ++samples_;
      if (samples_ == 8) {
        // Measure the real CPU compositor on this machine, at this camera
        // resolution and selected effect. Avoid forcing GPU on integrated
        // devices where staging readback is slower than optimized CPU code.
        Frame cpu;
        const auto cpu_started = std::chrono::steady_clock::now();
        if (realtime_processed_video::Compose(camera, mask, *settings, &cpu)) {
          const auto cpu_finished = std::chrono::steady_clock::now();
          cpu_baseline_ms_ =
              std::chrono::duration<double, std::milli>(
                  cpu_finished - cpu_started).count();
          if (gpu_total_ms_ / samples_ > cpu_baseline_ms_ * 1.12) {
            disabled_ = true;
            *output = std::move(cpu);
          }
        }
      }
    } else if (cpu_baseline_ms_ > 0) {
      // Dynamic backoff for GPU contention (for example a game/encoder
      // taking over a small laptop GPU). Never oscillate rapidly.
      moving_gpu_ms_ = moving_gpu_ms_ == 0 ? gpu_ms
          : moving_gpu_ms_ * 0.92 + gpu_ms * 0.08;
      if (++steady_samples_ >= 40 &&
          moving_gpu_ms_ > cpu_baseline_ms_ * 1.3)
        disabled_ = true;
    }
    return true;
  }

 private:
  using ComPtrDevice = Microsoft::WRL::ComPtr<ID3D11Device>;
  using ComPtrContext = Microsoft::WRL::ComPtr<ID3D11DeviceContext>;
  template<typename T> using ComPtr = Microsoft::WRL::ComPtr<T>;

  struct Texture {
    ComPtr<ID3D11Texture2D> resource;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11UnorderedAccessView> uav;
    void Clear() {
      uav.Reset();
      srv.Reset();
      resource.Reset();
    }
  };

  struct alignas(16) Parameters {
    std::uint32_t width, height, mask_width, mask_height;
    std::uint32_t background_width, background_height, blur_radius, mode;
  };

  bool Initialize() {
    ComPtr<IDXGIFactory1> factory;
    ComPtr<IDXGIAdapter1> preferred;
    if (SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
      SIZE_T largest_memory = 0;
      for (UINT i = 0; i < 16; ++i) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(i, &adapter) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_ADAPTER_DESC1 info{};
        if (FAILED(adapter->GetDesc1(&info)) ||
            (info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE)) continue;
        if (!preferred || info.DedicatedVideoMemory > largest_memory) {
          preferred = adapter;
          largest_memory = info.DedicatedVideoMemory;
        }
      }
    }
    constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1,
                                            D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL actual = D3D_FEATURE_LEVEL_11_0;
    const auto create = [&](IDXGIAdapter* adapter, D3D_DRIVER_TYPE driver) {
      HRESULT hr = D3D11CreateDevice(
          adapter, driver, nullptr, D3D11_CREATE_DEVICE_SINGLETHREADED,
          levels, 2, D3D11_SDK_VERSION, &device_, &actual, &context_);
      if (hr == E_INVALIDARG)
        hr = D3D11CreateDevice(
            adapter, driver, nullptr, D3D11_CREATE_DEVICE_SINGLETHREADED,
            levels + 1, 1, D3D11_SDK_VERSION,
            &device_, &actual, &context_);
      return SUCCEEDED(hr) && device_ && context_;
    };
    if (!create(preferred.Get(), preferred ? D3D_DRIVER_TYPE_UNKNOWN
                                           : D3D_DRIVER_TYPE_HARDWARE)) {
      device_.Reset();
      context_.Reset();
      if (!create(nullptr, D3D_DRIVER_TYPE_HARDWARE)) return false;
    }
    if (actual < D3D_FEATURE_LEVEL_11_0) return false;
    UINT flags = 0;
    if (FAILED(device_->CheckFormatSupport(
            DXGI_FORMAT_R8G8B8A8_UNORM, &flags)) ||
        !(flags & D3D11_FORMAT_SUPPORT_TYPED_UNORDERED_ACCESS_VIEW))
      return false;
    if (!CompileShader("Horizontal", horizontal_) ||
        !CompileShader("HorizontalReduced", horizontal_reduced_) ||
        !CompileShader("Vertical", vertical_) ||
        !CompileShader("Composite", composite_))
      return false;
    D3D11_BUFFER_DESC desc{};
    desc.ByteWidth = sizeof(Parameters);
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    return SUCCEEDED(device_->CreateBuffer(
        &desc, nullptr, parameters_.GetAddressOf()));
  }

  bool CompileShader(const char* entry, ComPtr<ID3D11ComputeShader>& shader) {
    ComPtr<ID3DBlob> bytecode;
    ComPtr<ID3DBlob> errors;
    const HRESULT compiled = D3DCompile(
        kCompositorHlsl, std::strlen(kCompositorHlsl), "windows_effects",
        nullptr, nullptr, entry, "cs_5_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3, 0,
        bytecode.GetAddressOf(), errors.GetAddressOf());
    if (FAILED(compiled)) {
      if (errors) OutputDebugStringA(
          static_cast<const char*>(errors->GetBufferPointer()));
      return false;
    }
    return SUCCEEDED(device_->CreateComputeShader(
        bytecode->GetBufferPointer(), bytecode->GetBufferSize(), nullptr,
        shader.GetAddressOf()));
  }

  bool CreateTexture(Texture* target, std::uint32_t w, std::uint32_t h,
                     DXGI_FORMAT format, bool read, bool write) {
    target->Clear();
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = w;
    desc.Height = h;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = (read ? D3D11_BIND_SHADER_RESOURCE : 0) |
                     (write ? D3D11_BIND_UNORDERED_ACCESS : 0);
    if (FAILED(device_->CreateTexture2D(
            &desc, nullptr, target->resource.GetAddressOf())))
      return false;
    if (read && FAILED(device_->CreateShaderResourceView(
            target->resource.Get(), nullptr, target->srv.GetAddressOf())))
      return false;
    if (write && FAILED(device_->CreateUnorderedAccessView(
            target->resource.Get(), nullptr, target->uav.GetAddressOf())))
      return false;
    return true;
  }

  bool EnsureSize(std::uint32_t w, std::uint32_t h,
                  std::uint32_t mask_w, std::uint32_t mask_h) {
    if (w == width_ && h == height_ &&
        mask_w == mask_width_ && mask_h == mask_height_) return true;
    // Keep the original full-resolution foreground and 192x192 mask.
    // Only the blurred background needs reduced resolution: quarter-size
    // at 720p+ cuts the separable GPU blur's texture work substantially.
    blur_scale_ = (w >= 960 && h >= 540) ? 4u : 2u;
    const auto half_w = (w + blur_scale_ - 1) / blur_scale_;
    const auto half_h = (h + blur_scale_ - 1) / blur_scale_;
    if (!CreateTexture(&camera_, w, h, DXGI_FORMAT_R8G8B8A8_UNORM,
                       true, false) ||
        !CreateTexture(&mask_, mask_w, mask_h, DXGI_FORMAT_R32_FLOAT,
                       true, false) ||
        !CreateTexture(&output_, w, h, DXGI_FORMAT_R8G8B8A8_UNORM,
                       false, true) ||
        !CreateTexture(&blur_horizontal_, half_w, half_h,
                       DXGI_FORMAT_R8G8B8A8_UNORM, true, true) ||
        !CreateTexture(&blur_vertical_, half_w, half_h,
                       DXGI_FORMAT_R8G8B8A8_UNORM, true, true))
      return false;
    D3D11_TEXTURE2D_DESC staging{};
    staging.Width = w;
    staging.Height = h;
    staging.MipLevels = staging.ArraySize = 1;
    staging.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    staging.SampleDesc.Count = 1;
    staging.Usage = D3D11_USAGE_STAGING;
    staging.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    readback_.Reset();
    if (FAILED(device_->CreateTexture2D(
            &staging, nullptr, readback_.GetAddressOf()))) return false;
    width_ = w;
    height_ = h;
    mask_width_ = mask_w;
    mask_height_ = mask_h;
    return true;
  }

  bool Upload(
      const realtime_processed_video::Frame& camera,
      const realtime_processed_video::PersonMask& mask,
      const std::shared_ptr<const realtime_processed_video::BackgroundSettings>&
          settings) {
    context_->UpdateSubresource(camera_.resource.Get(), 0, nullptr,
        camera.pixels->data(), camera.stride, 0);
    context_->UpdateSubresource(mask_.resource.Get(), 0, nullptr,
        mask.alpha.data(), mask.width * sizeof(float), 0);
    if (settings->mode != realtime_processed_video::BackgroundMode::replace_image)
      return true;
    if (!settings->replacement_width || !settings->replacement_height ||
        settings->replacement_width > 4096 ||
        settings->replacement_height > 4096 ||
        settings->replacement_bgra.size() <
          static_cast<std::size_t>(settings->replacement_width) *
              settings->replacement_height * 4)
      return false;
    if (cached_replacement_.lock() != settings) {
      if (!CreateTexture(&replacement_, settings->replacement_width,
                         settings->replacement_height,
                         DXGI_FORMAT_R8G8B8A8_UNORM, true, false))
        return false;
      context_->UpdateSubresource(
          replacement_.resource.Get(), 0, nullptr,
          settings->replacement_bgra.data(), settings->replacement_width * 4, 0);
      cached_replacement_ = settings;
    }
    return true;
  }

  void Dispatch(ID3D11ComputeShader* shader,
                ID3D11ShaderResourceView* a,
                ID3D11ShaderResourceView* b,
                ID3D11ShaderResourceView* c,
                ID3D11UnorderedAccessView* output,
                std::uint32_t w, std::uint32_t h) {
    ID3D11ShaderResourceView* reads[3]{a, b, c};
    context_->CSSetShader(shader, nullptr, 0);
    context_->CSSetShaderResources(0, 3, reads);
    context_->CSSetUnorderedAccessViews(0, 1, &output, nullptr);
    context_->Dispatch((w + 7) / 8, (h + 7) / 8, 1);
    ID3D11ShaderResourceView* empty_reads[3]{};
    ID3D11UnorderedAccessView* empty_writes[1]{};
    context_->CSSetUnorderedAccessViews(0, 1, empty_writes, nullptr);
    context_->CSSetShaderResources(0, 3, empty_reads);
  }

  bool DispatchFrame(
      const realtime_processed_video::Frame& camera,
      const realtime_processed_video::BackgroundSettings& settings) {
    const bool is_blur =
        settings.mode == realtime_processed_video::BackgroundMode::blur;
    const auto bw = is_blur ? (width_ + blur_scale_ - 1) / blur_scale_
                             : settings.replacement_width;
    const auto bh = is_blur ? (height_ + blur_scale_ - 1) / blur_scale_
                             : settings.replacement_height;
    const auto blur_plan = ChooseWindowsBlurPlan(settings.blur_radius,
                                                blur_scale_);
    const Parameters params{
      width_, height_, mask_width_, mask_height_, bw, bh,
      blur_plan.radius,
      static_cast<std::uint32_t>(is_blur ? 1 : 2)};
    context_->UpdateSubresource(parameters_.Get(), 0, nullptr, &params, 0, 0);
    ID3D11Buffer* constant = parameters_.Get();
    context_->CSSetConstantBuffers(0, 1, &constant);
    if (is_blur) {
      Dispatch(horizontal_.Get(), camera_.srv.Get(), nullptr, nullptr,
               blur_horizontal_.uav.Get(), bw, bh);
      Dispatch(vertical_.Get(), nullptr, nullptr, blur_horizontal_.srv.Get(),
               blur_vertical_.uav.Get(), bw, bh);
      for (std::uint32_t pass = 1; pass < blur_plan.passes; ++pass) {
        Dispatch(horizontal_reduced_.Get(), nullptr, nullptr,
                 blur_vertical_.srv.Get(), blur_horizontal_.uav.Get(), bw, bh);
        Dispatch(vertical_.Get(), nullptr, nullptr,
                 blur_horizontal_.srv.Get(), blur_vertical_.uav.Get(), bw, bh);
      }
    }
    Dispatch(composite_.Get(), camera_.srv.Get(), mask_.srv.Get(),
             is_blur ? blur_vertical_.srv.Get() : replacement_.srv.Get(),
             output_.uav.Get(), width_, height_);
    context_->CopyResource(readback_.Get(), output_.resource.Get());
    return true;
  }

  bool Readback(
      const realtime_processed_video::Frame& camera,
      const std::shared_ptr<const realtime_processed_video::BackgroundSettings>&
          settings,
      realtime_processed_video::Frame* output) {
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(context_->Map(readback_.Get(), 0, D3D11_MAP_READ,
                             0, &mapped))) return false;
    auto pixels = output_buffers_.Acquire(
        static_cast<std::size_t>(width_) * height_ * 4);
    for (std::uint32_t y = 0; y < height_; ++y) {
      std::memcpy(
          pixels->data() + static_cast<std::size_t>(y) * width_ * 4,
          static_cast<const std::uint8_t*>(mapped.pData) +
              static_cast<std::size_t>(y) * mapped.RowPitch,
          static_cast<std::size_t>(width_) * 4);
    }
    context_->Unmap(readback_.Get(), 0);
    *output = realtime_processed_video::Frame{
        camera.source_id, std::move(pixels), width_, height_, width_ * 4,
        camera.timestamp_ns,
        settings->mode != realtime_processed_video::BackgroundMode::none};
    return true;
  }

  ComPtrDevice device_;
  VideoPixelPool output_buffers_;
  ComPtrContext context_;
  ComPtr<ID3D11ComputeShader> horizontal_, horizontal_reduced_, vertical_,
      composite_;
  ComPtr<ID3D11Buffer> parameters_;
  Texture camera_, mask_, output_, blur_horizontal_, blur_vertical_, replacement_;
  ComPtr<ID3D11Texture2D> readback_;
  std::weak_ptr<const realtime_processed_video::BackgroundSettings>
      cached_replacement_;
  std::uint32_t width_ = 0, height_ = 0, mask_width_ = 0, mask_height_ = 0;
  std::uint32_t blur_scale_ = 2;
  bool initialized_ = false, disabled_ = false;
  int samples_ = 0, steady_samples_ = 0;
  double gpu_total_ms_ = 0, cpu_baseline_ms_ = 0, moving_gpu_ms_ = 0;
};

}  // namespace realtime_video_effects
