/*
  Warnings:

  - Added the required column `salt` to the `OtpChallenge` table without a default value. This is not possible if the table is not empty.

*/
-- AlterTable
ALTER TABLE "OtpChallenge" ADD COLUMN     "salt" TEXT NOT NULL;

-- CreateIndex
CREATE INDEX "OtpChallenge_phone_createdAt_idx" ON "OtpChallenge"("phone", "createdAt");
