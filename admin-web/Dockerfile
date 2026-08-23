FROM node:24-alpine AS build
WORKDIR /app
COPY admin-web/package.json admin-web/package-lock.json ./
RUN npm ci
COPY admin-web ./
RUN npm run build

FROM nginx:1.29-alpine
COPY admin-web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html/admin
USER 101:101
EXPOSE 8080
