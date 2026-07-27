@echo off
rem Run the NavCore test suite on Windows: sets up the MSVC linker
rem environment Swift needs, then delegates to SwiftPM.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
swift test --package-path "%~dp0" %*
