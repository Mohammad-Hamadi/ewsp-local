FROM node:22-alpine AS builder

WORKDIR /workspace

COPY package.json package-lock.json ./
RUN npm ci

COPY index.html vite.config.ts tsconfig.json tsconfig.app.json tsconfig.node.json ./
COPY public/ public/
COPY src/ src/

ARG VITE_API_BASE_URL=http://localhost:8080
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}

RUN npm run build

FROM nginx:1.28-alpine AS runtime

COPY --from=builder /workspace/dist/ /usr/share/nginx/html/
COPY --from=orchestration docker/dashboard.nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
