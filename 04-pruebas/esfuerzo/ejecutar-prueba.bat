@echo off
chcp 65001 >nul
rem ===================================================================
rem  PRUEBAS DE ESFUERZO - EduNova por Tailscale (se ejecuta en la PC)
rem  Requiere k6:  winget install k6 --source winget   (una sola vez)
rem  Al terminar abre el informe HTML con graficas (sirve para el informe).
rem ===================================================================
cd /d "%~dp0"
where k6 >nul 2>&1 || if exist "%ProgramFiles%\k6\k6.exe" set "PATH=%ProgramFiles%\k6;%PATH%"
where k6 >nul 2>&1 || (echo Falta k6. Instalalo con:  winget install k6 --source winget & echo y abre una ventana de CMD nueva. & pause & exit /b 1)
set /p URL=Direccion de EduNova (la misma del navegador, ej. https://.../plataforma): 
set /p CLAVE=Clave de las cuentas de prueba: 
set /p MAX=Estudiantes simultaneos al final [100]: 
if "%MAX%"=="" set MAX=100
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmm"') do set TS=%%i
set K6_WEB_DASHBOARD=true
set K6_WEB_DASHBOARD_EXPORT=informe-%MAX%usuarios-%TS%.html
echo.
echo Prueba de unos 11 minutos con hasta %MAX% estudiantes. Mientras corre puedes ver las graficas en vivo en
echo   http://127.0.0.1:5665    y en Zabbix la CPU/memoria de los servidores.
echo.
k6 run -e URL=%URL% -e CLAVE=%CLAVE% -e MAX=%MAX% carga-edunova.js
echo.
echo Informe guardado: %K6_WEB_DASHBOARD_EXPORT%
if exist "%K6_WEB_DASHBOARD_EXPORT%" start "" "%K6_WEB_DASHBOARD_EXPORT%"
set CLAVE=
pause
