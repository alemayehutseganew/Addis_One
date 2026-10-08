# Addis One Backend - Free Deployment Guide

## Quick Start: Railway (Recommended - Easiest Free Tier)

Railway provides free PostgreSQL, Redis, and hosting with a generous free tier.

### 1. Create Railway Account
- Go to https://railway.app
- Sign up with GitHub

### 2. Create Project
1. Click "New Project" → "Deploy from GitHub repo"
2. Select `alemayehutseganew/Addis_One`
3. Set root directory to `backend`

### 3. Add Database & Redis
1. In project dashboard, click "New Service" → "Database" → "PostgreSQL"
2. Click "New Service" → "Database" → "Redis"

### 4. Configure Environment Variables
In the backend service, add these variables:

```
NODE_ENV=production
PORT=3000
DATABASE_URL=${{Postgres.DATABASE_URL}}
REDIS_URL=${{Redis.REDIS_URL}}
JWT_ACCESS_SECRET=your-32-char-secret-here
JWT_REFRESH_SECRET=another-32-char-secret-here
OTP_DEV_ECHO=false
TEST_LOGIN_ENABLED=true
TEST_PASSENGER_USERNAME=passenger
TEST_PASSENGER_PASSWORD=test123
TEST_STAFF_USERNAME=staff
TEST_STAFF_PASSWORD=test123
CORS_ORIGINS=*
QR_SIGNING_KEY_ID=prod-key-1
QR_PRIVATE_KEY_BASE64=
PAYMENT_DEFAULT_PROVIDER=MOCK
```

### 5. Deploy
- Railway auto-detects the Dockerfile and deploys
- Get your URL from the backend service (e.g., `https://addis-one-backend.up.railway.app`)

### 6. Update Mobile App
```powershell
.\scripts\build-release-apk.ps1 -BackendHost addis-one-backend.up.railway.app
```

---

## Alternative: Render

### 1. Create Render Account
- Go to https://render.com
- Sign up with GitHub

### 2. Create PostgreSQL Database
- New → PostgreSQL → Free tier
- Note the connection string

### 3. Create Redis
- New → Redis → Free tier
- Note the connection string

### 4. Create Web Service
- New → Web Service → Connect GitHub repo
- Root directory: `backend`
- Build command: `npm ci && npm run build`
- Start command: `npm run start:prod`

### 5. Add Environment Variables
Same as Railway above, using Render's connection strings.

### 6. Deploy
- Get your URL (e.g., `https://addis-one-backend.onrender.com`)

---

## Alternative: Fly.io

### 1. Install flyctl
```powershell
iwr https://fly.io/install.ps1 -useb | iex
```

### 2. Login & Launch
```powershell
fly auth login
cd backend
fly launch --no-deploy
```

### 3. Create PostgreSQL & Redis
```powershell
fly postgres create --name addis-one-db
fly redis create --name addis-one-redis
```

### 4. Attach to App
```powershell
fly postgres attach addis-one-db
fly redis attach addis-one-redis
```

### 5. Set Secrets
```powershell
fly secrets set JWT_ACCESS_SECRET="your-secret" JWT_REFRESH_SECRET="your-secret" OTP_DEV_ECHO=false TEST_LOGIN_ENABLED=true
```

### 6. Deploy
```powershell
fly deploy
```

---

## Generate Secrets

```powershell
# Generate JWT secrets (32+ chars)
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"

# Generate QR signing key
openssl genpkey -algorithm ed25519 -out qr_private.pem
# Then base64 encode:
cat qr_private.pem | base64 -w 0
```

---

## After Deployment

1. **Test the API**: Visit `https://your-backend-url/api/v1/health`
2. **Test password login**: 
   ```bash
   curl -X POST https://your-backend-url/api/v1/auth/password-login \
     -H "Content-Type: application/json" \
     -d '{"username":"passenger","password":"test123"}'
   ```
3. **Rebuild mobile APK** with new backend URL:
   ```powershell
   .\scripts\build-release-apk.ps1 -BackendHost your-backend-domain.com
   ```
4. **Create GitHub Release** with the new APK

---

## Free Tier Limits

| Platform | PostgreSQL | Redis | Hosting | Custom Domain |
|----------|------------|-------|---------|---------------|
| Railway  | 500MB      | 256MB | 500h/mo | Yes           |
| Render   | 90 days free | 25MB | 750h/mo | Yes           |
| Fly.io   | 3GB free   | 256MB | 3 shared VMs | Yes         |

---

## Production Checklist

- [ ] `NODE_ENV=production`
- [ ] `OTP_DEV_ECHO=false`
- [ ] `JWT_ACCESS_SECRET` ≥ 32 chars
- [ ] `JWT_REFRESH_SECRET` ≥ 32 chars
- [ ] Real PostgreSQL (not local)
- [ ] Real Redis (not local)
- [ ] `CORS_ORIGINS` set to your domain
- [ ] QR signing key generated
- [ ] HTTPS enabled (automatic on all platforms above)
- [ ] Custom domain configured (optional)