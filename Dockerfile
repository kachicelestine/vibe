# syntax=docker/dockerfile:1
# =============================================================================
# Multi-stage build for Vibe – AI-Powered Application Builder
#
# Stages
#   base    – shared Node.js + system deps
#   deps    – npm install (prod + dev), prisma generate
#   builder – next build (produces .next/standalone)
#   runner  – minimal production image (~200 MB vs ~1 GB naive)
# =============================================================================

###############################################################################
# Stage 1 – base
###############################################################################
FROM node:20-alpine AS base
# libc6-compat: required by some native Node addons on Alpine (musl libc)
# openssl:      required by Prisma query engine at runtime
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

###############################################################################
# Stage 2 – deps: install ALL dependencies so postinstall (prisma generate) runs
###############################################################################
FROM base AS deps
COPY package.json package-lock.json ./
# Copy schema first so `prisma generate` (postinstall) can resolve it
COPY prisma ./prisma/
RUN npm ci

###############################################################################
# Stage 3 – builder: compile the Next.js application
###############################################################################
FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ENV NEXT_TELEMETRY_DISABLED=1

# ---------------------------------------------------------------------------
# NEXT_PUBLIC_* variables are inlined into the JavaScript bundle at build time.
# Pass them via --build-arg when the image is tied to a specific environment.
# Example:
#   docker build \
#     --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_live_... \
#     --build-arg NEXT_PUBLIC_APP_URL=https://app.example.com \
#     -t vibe .
# ---------------------------------------------------------------------------
ARG NEXT_PUBLIC_APP_URL=http://localhost:3000
ARG NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
ARG NEXT_PUBLIC_CLERK_SIGN_IN_URL=/sign-in
ARG NEXT_PUBLIC_CLERK_SIGN_UP_URL=/sign-up
ARG NEXT_PUBLIC_CLERK_SIGN_IN_FALLBACK_REDIRECT_URL=/
ARG NEXT_PUBLIC_CLERK_SIGN_UP_FALLBACK_REDIRECT_URL=/

ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL
ENV NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
ENV NEXT_PUBLIC_CLERK_SIGN_IN_URL=$NEXT_PUBLIC_CLERK_SIGN_IN_URL
ENV NEXT_PUBLIC_CLERK_SIGN_UP_URL=$NEXT_PUBLIC_CLERK_SIGN_UP_URL
ENV NEXT_PUBLIC_CLERK_SIGN_IN_FALLBACK_REDIRECT_URL=$NEXT_PUBLIC_CLERK_SIGN_IN_FALLBACK_REDIRECT_URL
ENV NEXT_PUBLIC_CLERK_SIGN_UP_FALLBACK_REDIRECT_URL=$NEXT_PUBLIC_CLERK_SIGN_UP_FALLBACK_REDIRECT_URL

RUN npm run build

###############################################################################
# Stage 4 – runner: production image (standalone output only)
###############################################################################
FROM base AS runner

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Principle of least privilege – never run as root in production
RUN addgroup --system --gid 1001 nodejs && \
    adduser  --system --uid 1001 nextjs

COPY --from=builder /app/public ./public

RUN mkdir .next && chown nextjs:nodejs .next

# next build output: "standalone" mode copies only what the server needs to run.
# Static assets must be copied separately (they are not included in standalone).
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static    ./.next/static

# Prisma schema – needed if the app calls `prisma migrate deploy` on startup
COPY --from=builder --chown=nextjs:nodejs /app/prisma ./prisma

# Prisma generated client (custom output path: src/generated/prisma)
# The query engine binary (.node) must land alongside the JS client or Prisma
# won't be able to open it at runtime.
COPY --from=builder --chown=nextjs:nodejs /app/src/generated ./src/generated

USER nextjs

EXPOSE 3000

ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

CMD ["node", "server.js"]
