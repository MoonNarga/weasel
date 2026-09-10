-- 工作区的xmake.lua
set_project("weasel")

-- 定义全局变量
set_xmakever("2.9.4")
set_languages("c++17")
set_runtimes("MT")  -- 设置运行时库为静态链接，避免/MD与/MT冲突
add_defines("UNICODE", "_UNICODE")
add_defines("WINDOWS")
add_defines("MSVC")

-- Machine-specific paths live in an ignored file, not in the build script.
local deps_file = path.join(os.projectdir(), "xmake.local.lua")
weasel_deps = {}
if os.isfile(deps_file) then
  includes(deps_file)
end
local deps = weasel_deps
local dependency_errors = {}
if type(deps) ~= "table" then
  table.insert(dependency_errors, "xmake.local.lua must define a weasel_deps table")
  deps = {}
end
local function dependency_path(name, fallback)
  local value = deps[name]
  if type(value) == "table" then
    value = value[get_config("arch")] or value.default
  end
  value = value or fallback
  if type(value) ~= "string" or #value == 0 then
    table.insert(dependency_errors, "Set " .. name .. " in xmake.local.lua (see xmake.local.lua.example)")
    value = "."
  end
  return path.absolute(value, os.projectdir())
end

-- xbuild.bat supplies release versions; local values allow IDE inspection.
local version = deps.version or {}
local version_major = os.getenv("VERSION_MAJOR") or version.major or "0"
local version_minor = os.getenv("VERSION_MINOR") or version.minor or "0"
local version_patch = os.getenv("VERSION_PATCH") or version.patch or "0"
local file_version = os.getenv("FILE_VERSION") or version.file or
  (version_major .. "." .. version_minor .. "." .. version_patch .. ".0")
local product_version = os.getenv("PRODUCT_VERSION") or version.product or file_version
add_defines("VERSION_MAJOR=" .. version_major,
            "VERSION_MINOR=" .. version_minor,
            "VERSION_PATCH=" .. version_patch)

add_includedirs("$(projectdir)/include")
boost_root = dependency_path("boost_root", os.getenv("BOOST_ROOT"))
boost_include_path = boost_root
boost_lib_path = dependency_path("boost_libdir", path.join(boost_root, "stage/lib"))
if not os.isfile(path.join(boost_root, "boost/version.hpp")) then
  table.insert(dependency_errors, "Invalid Boost root: " .. boost_root)
end
local rime_root = dependency_path("rime_root", "librime/dist")
add_includedirs(path.join(rime_root, "include"))
add_includedirs(boost_include_path)
add_linkdirs(boost_lib_path)
add_linkdirs(dependency_path("rime_libdir", path.join(rime_root, "lib")))
on_load(function (target)
  assert(#dependency_errors == 0, table.concat(dependency_errors, "\n"))
end)
add_cxflags("/utf-8 /MP /O2 /Oi /Gm- /EHsc /MT /GS /Gy /fp:precise /Zc:wchar_t /Zc:forScope /Zc:inline /external:W3 /Gd /TP")
add_ldflags("/TLBID:1 /DYNAMICBASE /NXCOMPAT")

-- 全局ATL lib路径
local atl_lib_dir = ''
dpi_manifest = ''
for include in string.gmatch(os.getenv("include") or "", "([^;]+)") do
  if atl_lib_dir=='' and include:match(".*ATLMFC\\include\\?$") then
    atl_lib_dir = include:replace("include$", "lib")
    dpi_manifest = include:replace("ATLMFC\\include$", "Include\\Manifest\\PerMonitorHighDPIAware.manifest")
  end
  add_includedirs(include)
end

add_includedirs("$(projectdir)/include/wtl")

if is_arch("x64") then
  add_linkdirs(dependency_path("platform_libdir", "lib64"))
  if atl_lib_dir ~= '' then add_linkdirs(atl_lib_dir .. "/x64") end
elseif is_arch("x86") then
  add_linkdirs(dependency_path("platform_libdir", "lib"))
  if atl_lib_dir ~= '' then add_linkdirs(atl_lib_dir .. "/x86") end
elseif is_arch("arm") then
  if atl_lib_dir ~= '' then add_linkdirs(atl_lib_dir .. "/arm") end
elseif is_arch("arm64") then
  if atl_lib_dir ~= '' then add_linkdirs(atl_lib_dir .. "/arm64") end
end

add_links("atls", "shell32", "advapi32", "gdi32", "user32", "uuid", "ole32")

includes("WeaselIPC", "WeaselUI", "WeaselTSF")

if is_arch("x64") or is_arch("x86") then
  includes("RimeWithWeasel", "WeaselIPCServer", "WeaselServer", "WeaselDeployer")
end

if is_arch("x86") then
  includes("WeaselSetup")
end

if is_mode("debug") then
  includes("test/TestWeaselIPC")
  includes("test/TestResponseParser")
else
  add_cxflags("/GL")
  add_ldflags("/LTCG /INCREMENTAL:NO", {force = true})
end

rule("subcmd")
  on_load(function(target)
    target:add("ldflags", "/SUBSYSTEM:CONSOLE")
  end)
rule("subwin")
  on_load(function(target)
    target:add("ldflags", "/SUBSYSTEM:WINDOWS")
  end)

rule("add_rcfiles")
  on_load(function(target)
    target:add("files", path.join(target:scriptdir(), "*.rc"),
      {defines = {"VERSION_MAJOR=" .. version_major,
      "VERSION_MINOR=" .. version_minor,
      "VERSION_PATCH=" .. version_patch,
      "FILE_VERSION=" .. file_version,
      "PRODUCT_VERSION=" .. product_version
    }})
  end)
rule("use_weaselconstants")
  on_load(function(target)
    function check_include_weasel_constants_in_dir(dir)
      local files = os.files(path.join(dir, "**.h"))
      table.join2(files, os.files(path.join(dir, "**.cpp")))
      for _, file in ipairs(files) do
        local content = io.readfile(file)
        if content:find('#include%s+"WeaselConstants%.h"') or content:find('#include%s+<WeaselConstants%.h>') then
          return true
        end
      end
      return false
    end
    if check_include_weasel_constants_in_dir(target:scriptdir()) then
      target:add("rcflags", {
        "/dVERSION_MAJOR=" .. (os.getenv("VERSION_MAJOR") or "0"),
        "/dVERSION_MINOR=" .. (os.getenv("VERSION_MINOR") or "0"),
        "/dVERSION_PATCH=" .. (os.getenv("VERSION_PATCH") or "0"),
        "/dFILE_VERSION=" .. (os.getenv("FILE_VERSION") or "\"0.0.0.0\""),
        "/dPRODUCT_VERSION=" .. (os.getenv("PRODUCT_VERSION") or "\"0.0.0.0\"")
      })
    end
  end)
