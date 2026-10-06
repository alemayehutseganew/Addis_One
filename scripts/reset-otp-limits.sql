-- Clears OTP challenges so a dashboard browser test can sign in again.
--
-- The OTP service allows 5 requests per phone per hour with a 45s resend
-- cooldown (backend/src/modules/auth/otp.service.ts). That limit is correct and
-- must not be weakened, so a test that needs a fresh code clears the history
-- instead of raising the ceiling.
--
-- Development-only. Run against the local database:
--   docker exec -i at-postgres psql -U addis -d addis_one < scripts/reset-otp-limits.sql
DELETE FROM "OtpChallenge"
 WHERE "phone" IN ('+251911000001', '+251911000002', '+251911000003', '+251911234567');