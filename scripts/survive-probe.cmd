@echo off
REM Survival probe. Determines whether a detached child process outlives the
REM foreground command that launched it. Every long-running step in this project
REM depends on the answer: if detached children are torn down with the parent,
REM no amount of polling will help and the builds must be made short instead.
ping -n 130 127.0.0.1 > nul
echo SURVIVED_AT=%TIME% >> "%TEMP%\survive.txt"