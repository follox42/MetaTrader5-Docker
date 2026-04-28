# Fork follox42/MetaTrader5-Docker — notes

Fork de [gmag11/MetaTrader5-Docker](https://github.com/gmag11/MetaTrader5-Docker)
avec patches pour Coolify + Proxmox + 2 modes de déploiement (RPyC only / REST+RPyC).

Voir aussi le [README upstream](README.md).

---

## Modes de déploiement

Deux Dockerfiles. Tu choisis lequel via Coolify UI → app → **General → Dockerfile location**.

### Mode 1 : RPyC seul (`/Dockerfile`, défaut)

```
[Bot Python] ──RPyC──> mt5linux :8001 ──> Wine ──> MT5 ──> FTMO
                       (binary protocol)
```

- Port `8001` : mt5linux RPyC server (Python clients only)
- Port `3000` : KasmVNC web UI (MT5 dans navigateur)
- Pas de HTTP REST → pas accessible via curl/Postman

**Quand l'utiliser** : ton bot est en Python et tourne dans le même réseau Docker (Coolify interne) ou via Cloudflare Tunnel + WARP.

### Mode 2 : REST + RPyC (`/Dockerfile.rest`)

```
[curl/Postman/JS bot] ──HTTP──> FastAPI :8000 ──RPyC──> mt5linux :8001 ──> Wine ──> MT5 ──> FTMO
                                  (JSON)                (localhost interne)
```

- Port `8001` : mt5linux RPyC (toujours dispo, comme mode 1)
- Port `3000` : KasmVNC web UI (idem)
- Port `8000` : **FastAPI REST API** (nouveau)

Endpoints REST :

| Méthode | Path | Description |
|---|---|---|
| GET | `/health` | service alive + RPyC connecté |
| GET | `/account` | infos compte FTMO (login, balance, equity, leverage) |
| GET | `/positions` | positions ouvertes |
| GET | `/symbols` | liste des symboles disponibles |
| GET | `/symbol/{name}` | infos symbole + dernier tick |
| GET | `/candles?symbol=X&timeframe=M1&count=N` | bougies OHLCV |
| POST | `/order` | place ordre marché |

Body POST `/order` :
```json
{
  "symbol": "EURUSD",
  "type": "buy",
  "volume": 0.01,
  "sl": 0,
  "tp": 0,
  "comment": "rest-api"
}
```

**Quand l'utiliser** : tu veux des URLs HTTP REST consommables par n'importe quel client (curl, Postman, JS, Go, etc.) via Cloudflare HTTPS proxy normal.

---

## Comment switcher entre les 2 modes

Dans Coolify UI :

1. App `mt5-ftmo` → **General**
2. **Dockerfile location** :
   - `/Dockerfile` → mode 1 (RPyC seul)
   - `/Dockerfile.rest` → mode 2 (REST + RPyC + VNC)
3. **Save** → **Redeploy**

Les ports exposés s'adaptent automatiquement :
- mode 1 : `8001,3000`
- mode 2 : `8000,8001,3000` (ajoute 8000 pour FastAPI)

Pense à mettre à jour le routing Traefik / domaine pour pointer vers `:8000` en mode 2 (sinon la HTTPS via Cloudflare arrive sur :8001 RPyC = 502).

---

## Patches du fork vs upstream

8 fixes dans `Metatrader/start.sh` :

1. `wineboot --init` upfront sur volume neuf
2. Mono.msi téléchargé dans `/tmp/` (pas `/config/.wine/drive_c/`)
3. mt5setup.exe idem `/tmp/`
4. `mt5linux==0.1.9 --force-reinstall` Linux + Wine (1.0+ a supprimé le switch `-w`)
5. Bypass `is_*_installed` checks pour mt5linux
6. **Mono toujours réinstallé** chaque boot (idempotent, +30s)
7. **MT5 install timeout 10 min** + polling logs every 60s
8. **`wait $MT5LINUX_PID` à la fin** — sans ça linuxserver supervisord détecte exit + restart loop infini

---

## Prérequis Coolify

- App créée via Public Repository (cette URL)
- Build pack : **Dockerfile**
- Custom Docker Run Options : `--security-opt seccomp=unconfined`
- Volume persistant : `/config`
- Env vars :
  - `CUSTOM_USER` : utilisateur KasmVNC web
  - `PASSWORD` : mot de passe KasmVNC web
  - `MT5_CMD_OPTIONS` : `/portable /login:XXX /password:YYY /server:FTMO-Demo` (auto-login)
  - `TZ` : `Europe/Paris`

## Prérequis hôte (Proxmox VM)

VM CPU type doit être **`host`** (pas `kvm64` / `x86-64-v2-AES`) — sinon Wine hang silent à 13MB RSS faute d'AVX2/BMI/FMA.

```bash
qm shutdown <VMID>
qm set <VMID> --cpu host
qm start <VMID>
```

Vérifier dans la VM :
```bash
cat /proc/cpuinfo | grep -oE "avx[0-9]*|bmi[0-9]*|fma" | sort -u
# doit afficher : avx avx2 bmi1 bmi2 fma
```
