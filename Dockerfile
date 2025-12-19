
FROM node:18-alpine

WORKDIR /app

RUN apk add --no-cache curl libc6-compat

COPY package.json package-lock.json ./

RUN npm install --registry=https://registry.npmmirror.com
COPY . .