FROM node:24-alpine AS build
WORKDIR /repo/admin-web
COPY admin-web/package.json admin-web/package-lock.json ./
RUN npm ci
COPY admin-web ./
COPY scripts/sync-website-assets.mjs /repo/scripts/sync-website-assets.mjs
COPY website /repo/website
RUN npm run build

FROM nginx:1.29-alpine
COPY admin-web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /repo/admin-web/dist /usr/share/nginx/html/admin
USER 101:101
EXPOSE 8080
