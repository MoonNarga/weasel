@echo off
setlocal
if not defined BOOST_ROOT (
  echo Set BOOST_ROOT and run from an x64 VS Developer Command Prompt.
  exit /b 1
)
pushd "%~dp0..\.."
if not exist output\local-tests\candidate-ui mkdir output\local-tests\candidate-ui
cl /nologo /c /std:c++17 /utf-8 /EHsc /MT /O2 /DUNICODE /D_UNICODE /DVERSION_MAJOR=0 /DVERSION_MINOR=17 /DVERSION_PATCH=4 /IWeaselTSF /Iinclude /I"%BOOST_ROOT%" test\TestCandidateUI\TestCandidateUI.cpp /Fooutput\local-tests\candidate-ui\test.obj
if errorlevel 1 goto failure
link /nologo /LTCG /SUBSYSTEM:CONSOLE /OUT:output\local-tests\candidate-ui\TestCandidateUI.exe output\local-tests\candidate-ui\test.obj msbuild\Release\x64\WeaselTSF\*.obj msbuild\Release\x64\WeaselIPC.lib msbuild\Release\x64\WeaselUI.lib /LIBPATH:"%BOOST_ROOT%\stage\lib" user32.lib gdi32.lib advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib usp10.lib
if errorlevel 1 goto failure
output\local-tests\candidate-ui\TestCandidateUI.exe
if errorlevel 1 goto failure
copy /y output\local-tests\candidate-ui\TestCandidateUI.exe output\local-tests\candidate-ui\dota2.exe >nul
output\local-tests\candidate-ui\dota2.exe --game
if errorlevel 1 goto failure
popd
exit /b 0
:failure
popd
exit /b 1
