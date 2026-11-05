# Homarr Windows Edition — status testu wykonalności

## Cel

Natywny serwer Homarr dla Windows 11 x64 bez Dockera i WSL2. Ten dokument opisuje przeszkody znane na etapie audytu i sposób uruchomienia eksperymentalnego workflow.

## Aktualny test GitHub Actions

Workflow: `.github/workflows/windows-feasibility.yml`

Uruchomienie ręczne:

1. Otwórz repozytorium na GitHub.
2. Przejdź do `Actions` -> `Windows feasibility`.
3. Wybierz `Run workflow`.
4. Gałąź: `windows-native`.
5. Poczekaj na wynik kroku `Verify native modules` i `Build CLI and Next.js`.

Test sprawdza:

- instalację zależności przez Bun z `bun.lock`,
- natywne moduły `better-sqlite3`, `bcrypt`, `sharp` na `windows-latest` / x64,
- kompilację `@homarr/nextjs` i `@homarr/cli`,
- dostępność natywnego serwera Redis dla Windows.

## Znane przeszkody

1. `better-sqlite3`, `bcrypt` i `sharp` wymagają poprawnych bindingów dla Windows x64. Błąd w kroku `Verify native modules` oznacza konieczność rebuildu lub zmiany wersji.
2. Skrypty startowe są bashowe (`scripts/run.sh`, `scripts/entrypoint.sh`) i używają ścieżek `/appdata`, `/run/nginx`, `/etc/nginx`, `envsubst`, `openssl`, `redis-server`.
3. Nginx pełni funkcje bezpieczeństwa i routingu: proxy do Next.js i websocketów, nagłówki `X-Real-IP`, `X-Homarr-Client-IP`, `X-Homarr-Proxy-Secret`, `X-Forwarded-*`, limit `client_max_body_size 256M`, konfiguracja trusted proxies. Nie można go usunąć bez zastąpienia tych funkcji.
4. Redis nie jest opcjonalny dla obecnej architektury. Natywny Redis dla Windows pozostaje nierozwiązanym problemem technicznym; kandydaci to Memurai lub port tpordowski/redis, wymagana weryfikacja z `packages/redis/redis.conf`. Workflow feasibility nie pobiera już przestarzałego Redis 5.0.14.1.
5. `AUTH_SECRET` i `HOMARR_REQUEST_IDENTITY_SECRET` są obecnie generowane przez `openssl`; na Windows wymagane będzie zastąpienie przez Node.js crypto lub inny mechanizm.
6. Ścieżki `/appdata/db`, `/appdata/redis`, `/appdata/trusted-certificates` muszą zostać przemapowane na katalog Windows, np. `%ProgramData%\Homarr`.

## Co nie jest jeszcze zrobione

- brak natywnego launchera Windows,
- brak usługi Windows,
- brak instalatora `Setup.exe`,
- brak testu uruchomienia serwera end-to-end na Windows.

## Następny krok

Jeśli workflow zakończy się sukcesem, kolejny etap to minimalny launcher PowerShell/Node uruchamiający migracje i Next.js, z zachowaniem ról nginx albo zastąpieniem ich w Node.js.