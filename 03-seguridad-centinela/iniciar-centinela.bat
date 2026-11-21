@echo off
REM Centinela Mejoland - iniciar la API (ML + LLM)
cd /d "%~dp0"
if not exist token.txt powershell -NoProfile -Command "[guid]::NewGuid().ToString('N') | Out-File -Encoding ascii -NoNewline token.txt"
set /p CENTINELA_TOKEN=<token.txt
set CENTINELA_LLM=http://127.0.0.1:11434
set CENTINELA_MODELO=qwen3:8b
python centinela.py
pause
