//! 所有生成文件的模板。
//!
//! 模板里用 `@@名字@@` 当占位符，**不用** std.fmt 的 `{}`，
//! 因为模板正文（尤其 .cs）里有大量花括号，用 fmt 得逐个转义 `{{` `}}`，太容易错。
//!
//! 占位符表：
//!   @@PLUGIN@@   插件/模块名，原样，例如 UEHtml2Md
//!   @@LOWER@@    全小写，例如 uehtml2md
//!   @@UPPER@@    全大写，例如 UEHTML2MD（用作模块导出宏前缀、头文件 include guard）
//!   @@RUST_DIR@@ Rust crate 目录名 = @@LOWER@@-dylib
//!   @@LIB@@      Rust 库名 = @@LOWER@@_dylib（产物 lib@@LIB@@.dylib / @@LIB@@.dll）

/// <Plugin>/<Plugin>.uplugin
pub const uplugin =
    \\{
    \\    "FileVersion": 3,
    \\    "Version": 1,
    \\    "VersionName": "1.0",
    \\    "FriendlyName": "@@PLUGIN@@",
    \\    "Description": "Rust 桥接插件，由 uerust 生成",
    \\    "Category": "Other",
    \\    "CreatedBy": "",
    \\    "CreatedByURL": "",
    \\    "DocsURL": "",
    \\    "MarketplaceURL": "",
    \\    "SupportURL": "",
    \\    "CanContainContent": true,
    \\    "IsBetaVersion": false,
    \\    "IsExperimentalVersion": false,
    \\    "Installed": false,
    \\    "Modules": [
    \\        {
    \\            "Name": "@@PLUGIN@@",
    \\            "Type": "Runtime",
    \\            "LoadingPhase": "Default"
    \\        }
    \\    ]
    \\}
    \\
;

/// <Plugin>/Source/<Plugin>/<Plugin>.Build.cs
pub const build_cs =
    \\using System;
    \\using System.IO;
    \\using UnrealBuildTool;
    \\
    \\public class @@PLUGIN@@ : ModuleRules
    \\{
    \\    public @@PLUGIN@@(ReadOnlyTargetRules Target) : base(Target)
    \\    {
    \\        PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;
    \\
    \\        PublicDependencyModuleNames.AddRange(new string[]
    \\        {
    \\            "Core",
    \\            "CoreUObject",
    \\            "Engine",
    \\        });
    \\
    \\        PrivateDependencyModuleNames.AddRange(new string[]
    \\        {
    \\            "Projects",
    \\            "Slate",
    \\            "SlateCore",
    \\        });
    \\
    \\        // ================= Rust 桥接 =================
    \\        //
    \\        // Rust crate 在 Source/@@RUST_DIR@@，头文件由 cbindgen 在 cargo build
    \\        // 时通过 build.rs 生成到它的 include/ 目录下。
    \\
    \\        string PluginDirectory = Path.GetFullPath(Path.Combine(ModuleDirectory, "..", ".."));
    \\        string RustDirectory = Path.Combine(ModuleDirectory, "..", "@@RUST_DIR@@");
    \\
    \\        // 只需要 include 路径，不需要链接 Rust 库：
    \\        // 所有符号都在运行时由 FPlatformProcess::GetDllHandle + GetDllExport 取，
    \\        // 这样 Windows 不需要额外的 .dll.lib import 库，三平台走同一条代码路径。
    \\        PublicIncludePaths.Add(Path.GetFullPath(Path.Combine(RustDirectory, "include")));
    \\
    \\        // 库文件由 `uerust build <PluginDir>` 拷到 Binaries/<Platform>/。
    \\        // 这里声明它必须被 staging 进打包结果，并且是 NonUFS ——
    \\        // dylib/dll/so 不能进 .pak，运行时没法从 pak 里 dlopen。
    \\        string RustLibraryName;
    \\        if (Target.Platform == UnrealTargetPlatform.Win64)
    \\        {
    \\            RustLibraryName = "@@LIB@@.dll";
    \\        }
    \\        else if (Target.Platform == UnrealTargetPlatform.Mac)
    \\        {
    \\            RustLibraryName = "lib@@LIB@@.dylib";
    \\        }
    \\        else
    \\        {
    \\            RustLibraryName = "lib@@LIB@@.so";
    \\        }
    \\
    \\        string StagedLibrary = Path.Combine(PluginDirectory, "Binaries", Target.Platform.ToString(), RustLibraryName);
    \\        if (File.Exists(StagedLibrary))
    \\        {
    \\            RuntimeDependencies.Add(StagedLibrary, StagedFileType.NonUFS);
    \\        }
    \\        else
    \\        {
    \\            Console.WriteLine("@@PLUGIN@@: 找不到 " + StagedLibrary + "，先跑 `uerust build \"" + PluginDirectory + "\"`");
    \\        }
    \\    }
    \\}
    \\
;

/// <Plugin>/Source/<Plugin>/Public/<Plugin>.h
pub const module_h =
    \\#pragma once
    \\
    \\#include "CoreMinimal.h"
    \\#include "Modules/ModuleManager.h"
    \\
    \\/**
    \\ * Rust 动态库导出的 C ABI 函数表。
    \\ * 函数名必须和 Rust 侧 #[no_mangle] extern "C" 的完全一致，
    \\ * 也和 build.rs 里 cbindgen 生成的头文件一致。
    \\ */
    \\struct F@@PLUGIN@@Ffi
    \\{
    \\    using FetchMarkdownFn = char* (*)(const char* Url);
    \\    using FreeStringFn = void (*)(char* Ptr);
    \\    using PluginVersionFn = const char* (*)();
    \\
    \\    FetchMarkdownFn FetchMarkdown = nullptr;
    \\    FreeStringFn FreeString = nullptr;
    \\    PluginVersionFn PluginVersion = nullptr;
    \\
    \\    bool IsValid() const { return FetchMarkdown && FreeString && PluginVersion; }
    \\};
    \\
    \\/**
    \\ * 插件模块。只干一件事：启动时 dlopen Rust 库并把函数指针取出来。
    \\ */
    \\class F@@PLUGIN@@Module : public IModuleInterface
    \\{
    \\public:
    \\    virtual void StartupModule() override;
    \\    virtual void ShutdownModule() override;
    \\
    \\    /** 已加载的 Rust 函数表。没加载成功时 IsValid() 返回 false。 */
    \\    static const F@@PLUGIN@@Ffi& GetFfi();
    \\
    \\    /** true 表示 Rust 库可用 */
    \\    static bool IsAvailable();
    \\
    \\private:
    \\    bool LoadRustLibrary();
    \\
    \\    void* LibraryHandle = nullptr;
    \\    F@@PLUGIN@@Ffi Ffi;
    \\};
    \\
;

/// <Plugin>/Source/<Plugin>/Private/<Plugin>.cpp
pub const module_cpp =
    \\#include "@@PLUGIN@@.h"
    \\
    \\#include "Containers/StringConv.h"
    \\#include "HAL/PlatformProcess.h"
    \\#include "Interfaces/IPluginManager.h"
    \\#include "Misc/Paths.h"
    \\
    \\#define LOCTEXT_NAMESPACE "F@@PLUGIN@@Module"
    \\
    \\namespace
    \\{
    \\    /** 当前平台的库文件名。和 Build.cs 里算出来的名字必须一致。 */
    \\    const TCHAR* RustLibraryFileName()
    \\    {
    \\#if PLATFORM_WINDOWS
    \\        return TEXT("@@LIB@@.dll");
    \\#elif PLATFORM_MAC
    \\        return TEXT("lib@@LIB@@.dylib");
    \\#else
    \\        return TEXT("lib@@LIB@@.so");
    \\#endif
    \\    }
    \\}
    \\
    \\bool F@@PLUGIN@@Module::LoadRustLibrary()
    \\{
    \\    const TSharedPtr<IPlugin> Plugin = IPluginManager::Get().FindPlugin(TEXT("@@PLUGIN@@"));
    \\    if (!Plugin.IsValid())
    \\    {
    \\        UE_LOG(LogTemp, Error, TEXT("@@PLUGIN@@: 找不到插件本体，IPluginManager 里没有 @@PLUGIN@@"));
    \\        return false;
    \\    }
    \\
    \\    const FString LibraryPath = FPaths::Combine(
    \\        Plugin->GetBaseDir(),
    \\        TEXT("Binaries"),
    \\        FPlatformProcess::GetBinariesSubdirectory(),
    \\        RustLibraryFileName());
    \\
    \\    if (!FPaths::FileExists(LibraryPath))
    \\    {
    \\        UE_LOG(LogTemp, Error,
    \\            TEXT("@@PLUGIN@@: 找不到 Rust 库 %s —— 在插件目录里跑 `uerust build .` 再重启编辑器"),
    \\            *LibraryPath);
    \\        return false;
    \\    }
    \\
    \\    LibraryHandle = FPlatformProcess::GetDllHandle(*LibraryPath);
    \\    if (!LibraryHandle)
    \\    {
    \\        UE_LOG(LogTemp, Error, TEXT("@@PLUGIN@@: 加载失败 %s"), *LibraryPath);
    \\        return false;
    \\    }
    \\
    \\    Ffi.FetchMarkdown = reinterpret_cast<F@@PLUGIN@@Ffi::FetchMarkdownFn>(
    \\        FPlatformProcess::GetDllExport(LibraryHandle, TEXT("uerust_fetch_markdown")));
    \\    Ffi.FreeString = reinterpret_cast<F@@PLUGIN@@Ffi::FreeStringFn>(
    \\        FPlatformProcess::GetDllExport(LibraryHandle, TEXT("uerust_free_string")));
    \\    Ffi.PluginVersion = reinterpret_cast<F@@PLUGIN@@Ffi::PluginVersionFn>(
    \\        FPlatformProcess::GetDllExport(LibraryHandle, TEXT("uerust_plugin_version")));
    \\
    \\    if (!Ffi.IsValid())
    \\    {
    \\        UE_LOG(LogTemp, Error,
    \\            TEXT("@@PLUGIN@@: 库打开了但符号没找齐。检查 Rust 侧是不是 #[no_mangle] pub extern \"C\"，函数名有没有拼错"));
    \\        FPlatformProcess::FreeDllHandle(LibraryHandle);
    \\        LibraryHandle = nullptr;
    \\        Ffi = F@@PLUGIN@@Ffi{};
    \\        return false;
    \\    }
    \\
    \\    UE_LOG(LogTemp, Log, TEXT("@@PLUGIN@@: Rust 库就绪 %s (%s)"),
    \\        *LibraryPath, UTF8_TO_TCHAR(Ffi.PluginVersion()));
    \\    return true;
    \\}
    \\
    \\void F@@PLUGIN@@Module::StartupModule()
    \\{
    \\    if (!LoadRustLibrary())
    \\    {
    \\        UE_LOG(LogTemp, Error, TEXT("@@PLUGIN@@: Rust 库不可用，插件功能全部不可用"));
    \\    }
    \\}
    \\
    \\void F@@PLUGIN@@Module::ShutdownModule()
    \\{
    \\    // 先清函数表再卸库，否则留着悬空指针
    \\    Ffi = F@@PLUGIN@@Ffi{};
    \\
    \\    if (LibraryHandle)
    \\    {
    \\        FPlatformProcess::FreeDllHandle(LibraryHandle);
    \\        LibraryHandle = nullptr;
    \\    }
    \\}
    \\
    \\const F@@PLUGIN@@Ffi& F@@PLUGIN@@Module::GetFfi()
    \\{
    \\    static const F@@PLUGIN@@Ffi Empty;
    \\    F@@PLUGIN@@Module* Module = FModuleManager::GetModulePtr<F@@PLUGIN@@Module>(TEXT("@@PLUGIN@@"));
    \\    return Module ? Module->Ffi : Empty;
    \\}
    \\
    \\bool F@@PLUGIN@@Module::IsAvailable()
    \\{
    \\    return GetFfi().IsValid();
    \\}
    \\
    \\#undef LOCTEXT_NAMESPACE
    \\
    \\IMPLEMENT_MODULE(F@@PLUGIN@@Module, @@PLUGIN@@)
    \\
;

/// <Plugin>/Source/<Plugin>/Public/<Plugin>Library.h
pub const library_h =
    \\#pragma once
    \\
    \\#include "CoreMinimal.h"
    \\#include "Kismet/BlueprintAsyncActionBase.h"
    \\#include "@@PLUGIN@@Library.generated.h"
    \\
    \\DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(F@@PLUGIN@@OnMarkdown, const FString&, Markdown);
    \\DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(F@@PLUGIN@@OnMarkdownFailed, const FString&, Error);
    \\
    \\/**
    \\ * 在后台线程调 Rust 抓网页并转 Markdown，完成后回主线程广播。
    \\ *
    \\ * 为什么不是普通 UFUNCTION：reqwest 会阻塞，跑在 GameThread 上网络一慢就掉帧。
    \\ * 这是异步节点，蓝图里搜 "Fetch Markdown From Url" 就能拿到。
    \\ */
    \\UCLASS()
    \\class @@UPPER@@_API U@@PLUGIN@@Library : public UBlueprintAsyncActionBase
    \\{
    \\    GENERATED_BODY()
    \\
    \\public:
    \\    UPROPERTY(BlueprintAssignable)
    \\    F@@PLUGIN@@OnMarkdown OnSuccess;
    \\
    \\    UPROPERTY(BlueprintAssignable)
    \\    F@@PLUGIN@@OnMarkdownFailed OnFail;
    \\
    \\    /**
    \\     * 抓取 Url 并把 HTML 转成 Markdown。
    \\     * @param Url 目标网页地址
    \\     */
    \\    UFUNCTION(BlueprintCallable, Category = "@@PLUGIN@@",
    \\        meta = (BlueprintInternalUseOnly = "true", WorldContext = "WorldContextObject",
    \\            DisplayName = "Fetch Markdown From Url"))
    \\    static U@@PLUGIN@@Library* FetchMarkdownFromUrl(const UObject* WorldContextObject, const FString& Url);
    \\
    \\    virtual void Activate() override;
    \\
    \\private:
    \\    UPROPERTY()
    \\    TObjectPtr<UObject> WorldContextObject = nullptr;
    \\
    \\    FString RequestUrl;
    \\};
    \\
;

/// <Plugin>/Source/<Plugin>/Private/<Plugin>Library.cpp
pub const library_cpp =
    \\#include "@@PLUGIN@@Library.h"
    \\
    \\#include "@@PLUGIN@@.h"
    \\#include "Async/Async.h"
    \\#include "Containers/StringConv.h"
    \\#include "Engine/GameInstance.h"
    \\
    \\U@@PLUGIN@@Library* U@@PLUGIN@@Library::FetchMarkdownFromUrl(const UObject* WorldContextObject, const FString& Url)
    \\{
    \\    U@@PLUGIN@@Library* Node = NewObject<U@@PLUGIN@@Library>();
    \\    Node->WorldContextObject = const_cast<UObject*>(WorldContextObject);
    \\    Node->RequestUrl = Url;
    \\    // 注册到 GameInstance：在 SetReadyToDestroy 之前这个节点不会被 GC 掉
    \\    Node->RegisterWithGameInstance(WorldContextObject);
    \\    return Node;
    \\}
    \\
    \\void U@@PLUGIN@@Library::Activate()
    \\{
    \\    // 先把函数表拷一份出来。后台线程里不要再去碰模块状态。
    \\    const F@@PLUGIN@@Ffi Ffi = F@@PLUGIN@@Module::GetFfi();
    \\
    \\    if (!Ffi.IsValid())
    \\    {
    \\        OnFail.Broadcast(TEXT("Rust 库没加载成功。在插件目录跑 `uerust build .`，然后重启编辑器。"));
    \\        SetReadyToDestroy();
    \\        return;
    \\    }
    \\
    \\    TWeakObjectPtr<U@@PLUGIN@@Library> WeakThis(this);
    \\    const FString UrlCopy = RequestUrl;
    \\
    \\    Async(EAsyncExecution::ThreadPool, [WeakThis, Ffi, UrlCopy]()
    \\    {
    \\        // ===== 这里是线程池，绝对不能碰任何 UObject =====
    \\        const FTCHARToUTF8 UrlUtf8(*UrlCopy);
    \\        char* Raw = Ffi.FetchMarkdown(UrlUtf8.Get());
    \\
    \\        FString Result;
    \\        if (Raw)
    \\        {
    \\            Result = FString(UTF8_TO_TCHAR(Raw));
    \\            // Rust 堆上的内存必须交回 Rust 释放，不能在 C++ 侧 delete
    \\            Ffi.FreeString(Raw);
    \\        }
    \\        else
    \\        {
    \\            Result = TEXT("Rust 侧返回了空指针");
    \\        }
    \\
    \\        AsyncTask(ENamedThreads::GameThread, [WeakThis, Result]()
    \\        {
    \\            if (U@@PLUGIN@@Library* Self = WeakThis.Get())
    \\            {
    \\                Self->OnSuccess.Broadcast(Result);
    \\                Self->SetReadyToDestroy();
    \\            }
    \\        });
    \\    });
    \\}
    \\
;

/// <Plugin>/Source/<RustDir>/Cargo.toml
pub const cargo_toml =
    \\[package]
    \\name = "@@RUST_DIR@@"
    \\version = "0.1.0"
    \\edition = "2021"
    \\
    \\[lib]
    \\# 关键：必须是 cdylib，不是 dylib。
    \\# dylib 是给 Rust 自己动态链接用的，跨语言 ABI 边界得用 cdylib。
    \\# 名字不能带横杠，所以这里是下划线，产物是 lib@@LIB@@.dylib / @@LIB@@.dll
    \\name = "@@LIB@@"
    \\crate-type = ["cdylib"]
    \\
    \\[dependencies]
    \\mdka = "1.2.10"
    \\reqwest = { version = "0.12.12", features = ["blocking"] }
    \\
    \\[build-dependencies]
    \\cbindgen = "0.27.0"
    \\
    \\[profile.release]
    \\opt-level = 3
    \\lto = true
    \\
;

/// <Plugin>/Source/<RustDir>/build.rs
pub const build_rs =
    \\//! cargo build 时自动跑 cbindgen，把 #[no_mangle] extern "C" 函数导出成 C++ 头文件。
    \\
    \\use std::path::PathBuf;
    \\use std::{env, fs};
    \\
    \\fn main() {
    \\    let crate_dir = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR 一定存在");
    \\    let include_dir = PathBuf::from(&crate_dir).join("include");
    \\
    \\    // cbindgen 的 write_to_file 不会自动建父目录，得先自己建，
    \\    // 否则第一次 clone 下来的人 build 会直接 panic。
    \\    fs::create_dir_all(&include_dir).expect("创建 include/ 失败");
    \\
    \\    let mut config: cbindgen::Config = Default::default();
    \\    // 生成 C++ 风格的 extern "C" 声明
    \\    config.language = cbindgen::Language::Cxx;
    \\    config.include_guard = Some("@@UPPER@@_FFI_H".to_string());
    \\    config.cpp_compat = true;
    \\    // 注释不进头文件，头文件要干净
    \\    config.documentation = false;
    \\
    \\    cbindgen::generate_with_config(&crate_dir, config)
    \\        .expect("cbindgen 生成头文件失败")
    \\        .write_to_file(include_dir.join("@@PLUGIN@@_ffi.h"));
    \\
    \\    println!("cargo:rerun-if-changed=src/lib.rs");
    \\}
    \\
;

/// <Plugin>/Source/<RustDir>/src/lib.rs
pub const lib_rs =
    \\//! @@PLUGIN@@ 的 Rust 侧实现。
    \\//!
    \\//! 规则：只有 `#[no_mangle] pub extern "C"` 的函数能跨过 FFI 边界。
    \\//! cbindgen 会把它们导出到 include/@@PLUGIN@@_ffi.h。
    \\//! 普通 Rust 函数（带 &str、String、Result 这些）一律不能直接暴露。
    \\
    \\use std::ffi::{CStr, CString};
    \\use std::os::raw::c_char;
    \\use std::sync::OnceLock;
    \\
    \\/// 真正的业务逻辑放这里，用正常的 Rust 类型，和 FFI 完全隔开。
    \\mod imp {
    \\    /// 抓 URL 并转 Markdown。返回 Result 而不是 panic，错误要能穿过 FFI 传回去。
    \\    pub fn fetch_markdown(url: &str) -> Result<String, String> {
    \\        let response = reqwest::blocking::get(url).map_err(|e| format!("请求失败: {e}"))?;
    \\        let response = response
    \\            .error_for_status()
    \\            .map_err(|e| format!("HTTP 状态错误: {e}"))?;
    \\        let html = response.text().map_err(|e| format!("读取响应体失败: {e}"))?;
    \\        Ok(mdka::from_html(&html))
    \\    }
    \\}
    \\
    \\/// 把 Rust String 变成交给 C++ 的裸指针。
    \\/// CString::new 只会因为字符串含 NUL 而失败，这里兜一下底。
    \\fn into_c_string(mut s: String) -> *mut c_char {
    \\    if s.as_bytes().contains(&0) {
    \\        s = s.replace('\0', " ");
    \\    }
    \\    CString::new(s)
    \\        .expect("已经过滤掉 NUL 了")
    \\        .into_raw()
    \\}
    \\
    \\/// 抓取 `url` 并把 HTML 转成 Markdown。
    \\///
    \\/// 返回的指针**必须**原样交给 `uerust_free_string` 释放，否则每次调用泄漏一块内存。
    \\/// 失败时不返回 NULL，而是返回一段可读的错误文本，C++ 侧直接显示就行。
    \\///
    \\/// 这个函数是阻塞的。C++ 侧必须在线程池里调用它，不要在 GameThread 上调。
    \\#[no_mangle]
    \\pub extern "C" fn uerust_fetch_markdown(url: *const c_char) -> *mut c_char {
    \\    if url.is_null() {
    \\        return into_c_string("url 是空指针".to_string());
    \\    }
    \\
    \\    // SAFETY: 调用方约定 url 是以 NUL 结尾的合法 C 字符串
    \\    let url = match unsafe { CStr::from_ptr(url) }.to_str() {
    \\        Ok(s) => s,
    \\        Err(e) => return into_c_string(format!("url 不是合法 UTF-8: {e}")),
    \\    };
    \\
    \\    match imp::fetch_markdown(url) {
    \\        Ok(markdown) => into_c_string(markdown),
    \\        Err(e) => into_c_string(format!("{e}\n(url = {url})")),
    \\    }
    \\}
    \\
    \\/// 释放 `uerust_fetch_markdown` 返回的指针。
    \\/// 传 NULL 是安全的；同一个指针不能释放两次。
    \\#[no_mangle]
    \\pub extern "C" fn uerust_free_string(ptr: *mut c_char) {
    \\    if ptr.is_null() {
    \\        return;
    \\    }
    \\    // SAFETY: 指针必须来自 into_c_string 里的 CString::into_raw
    \\    unsafe {
    \\        drop(CString::from_raw(ptr));
    \\    }
    \\}
    \\
    \\/// 返回静态字符串，**不需要**释放。
    \\/// 用来在 UE 里做一次零成本的加载自检 —— 能打出这行说明 FFI 通了。
    \\#[no_mangle]
    \\pub extern "C" fn uerust_plugin_version() -> *const c_char {
    \\    static VERSION: OnceLock<CString> = OnceLock::new();
    \\    VERSION
    \\        .get_or_init(|| {
    \\            CString::new(format!("@@PLUGIN@@ rust bridge {}", env!("CARGO_PKG_VERSION")))
    \\                .expect("版本号里不会有 NUL")
    \\        })
    \\        .as_ptr()
    \\}
    \\
    \\#[cfg(test)]
    \\mod tests {
    \\    use super::*;
    \\
    \\    #[test]
    \\    fn fetch_rejects_bad_url() {
    \\        assert!(imp::fetch_markdown("这不是一个 url").is_err());
    \\    }
    \\
    \\    #[test]
    \\    fn null_url_does_not_crash() {
    \\        let ptr = uerust_fetch_markdown(std::ptr::null());
    \\        assert!(!ptr.is_null());
    \\        uerust_free_string(ptr);
    \\    }
    \\
    \\    #[test]
    \\    fn version_is_readable() {
    \\        let ptr = uerust_plugin_version();
    \\        assert!(!ptr.is_null());
    \\        let s = unsafe { CStr::from_ptr(ptr) }.to_str().unwrap();
    \\        assert!(s.contains("@@PLUGIN@@"));
    \\    }
    \\}
    \\
;

/// <Plugin>/README.md
pub const plugin_readme =
    \\# @@PLUGIN@@
    \\
    \\UE5 C++ ⇄ Rust 插件，由 `uerust` 生成。
    \\
    \\## 目录
    \\
    \\```
    \\@@PLUGIN@@/
    \\  @@PLUGIN@@.uplugin
    \\  Source/
    \\    @@PLUGIN@@/              C++ 侧
    \\      @@PLUGIN@@.Build.cs
    \\      Public/@@PLUGIN@@.h            模块：dlopen Rust 库、取函数指针
    \\      Public/@@PLUGIN@@Library.h     蓝图异步节点（不卡帧）
    \\      Private/@@PLUGIN@@.cpp
    \\      Private/@@PLUGIN@@Library.cpp
    \\    @@RUST_DIR@@/            Rust 侧
    \\      Cargo.toml
    \\      build.rs           cargo build 时跑 cbindgen 生成头文件
    \\      src/lib.rs         业务逻辑 + FFI 导出
    \\      include/            cbindgen 产物（@@PLUGIN@@_ffi.h）
    \\  Binaries/<Platform>/     uerust build 把库拷到这里
    \\```
    \\
    \\## 接进 UE 项目
    \\
    \\**最简单**：把 `@@PLUGIN@@/` 整个拷进 `<项目>/Plugins/` 下。
    \\UE 会自动发现，`.uproject` 一个字不用改。
    \\
    \\**要显式启用**（团队/CI 同步状态，或插件不在项目目录里）：在 `MyGame.uproject`
    \\的 `"Plugins"` 数组里加一个对象（数组已存在就插进去，别整段替换）：
    \\
    \\```json
    \\"Plugins": [
    \\    {
    \\        "Name": "@@PLUGIN@@",
    \\        "Enabled": true
    \\    }
    \\]
    \\```
    \\
    \\插件放在项目目录之外时，再加一条外部插件目录（路径相对 `.uproject`，
    \\只对编辑器和源码构建有效，烤数据时会被引擎清空）：
    \\
    \\```json
    \\"AdditionalPluginDirectories": [
    \\    "../SharedPlugins"
    \\]
    \\```
    \\
    \\## 怎么用
    \\
    \\1. 放在 `<项目>/Plugins/@@PLUGIN@@/`，或按上面写进 `.uproject`。
    \\2. 构建 Rust 库：
    \\
    \\   ```
    \\   uerust build .
    \\   ```
    \\
    \\   它会跑 `cargo build --release`，然后把产物拷到 `Binaries/<Platform>/`。
    \\   **跳过这步 `Binaries/<Platform>/` 是空的，插件启动时加载库会失败。**
    \\3. 重新生成项目文件并编译 C++ 模块。
    \\4. 编辑器里「编辑 > 插件」确认已启用，蓝图搜 **Fetch Markdown From Url**，
    \\   接 `OnSuccess` / `OnFail`。
    \\
    \\## 改 Rust 代码时
    \\
    \\改完 `src/lib.rs` 再跑一次 `uerust build .`。**三步都要注意：**
    \\
    \\- 加了新的 FFI 函数，记得同步在 `Public/@@PLUGIN@@.h` 的 `F@@PLUGIN@@Ffi` 里加函数指针，
    \\  并在 `Private/@@PLUGIN@@.cpp` 里 `GetDllExport` 取出来。
    \\- FFI 函数必须 `#[no_mangle] pub extern "C"`，参数和返回值只能是 C 类型。
    \\- 返回 `*mut c_char` 的函数必须配一个 free 函数，C++ 侧用完立刻调，否则泄漏。
    \\
    \\## 几个设计取舍
    \\
    \\- **不静态链接 Rust 库**，全部走 `GetDllHandle` + `GetDllExport`。
    \\  好处是 Windows 不需要 `.dll.lib`，三平台一份逻辑。
    \\- **`crate-type = ["cdylib"]`**，不是 `dylib`。后者是给 Rust 之间动态链接用的。
    \\- **网络调用走线程池**。`reqwest::blocking` 会阻塞，在 GameThread 上就是掉帧。
    \\- **include/ 下的头文件建议提交进版本库**。它是 cbindgen 产物，
    \\  但 C++ 编译不依赖 cargo，没这个头文件 C++ 侧会报一堆看不懂的错。
    \\
    \\## 如果 Build.cs 报 StagedFileType 找不到
    \\
    \\把 `RuntimeDependencies.Add(StagedLibrary, StagedFileType.NonUFS);`
    \\改成 `RuntimeDependencies.Add(StagedLibrary);`
    \\（退化写法，库可能被打进 .pak，那时运行时 dlopen 会失败）。
    \\
;

/// <Plugin>/.gitignore
pub const gitignore =
    \\Binaries/
    \\Intermediate/
    \\Saved/
    \\Source/*-dylib/target/
    \\*.xcworkspace
    \\*.xcuserdata/
    \\*.sln
    \\*.suo
    \\*.opensdf
    \\*.sdf
    \\
;
