# Sample workload image (replace with the real application, e.g. Mattermost).
# nginx-unprivileged listens on 8080 and never runs as root.
FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html

EXPOSE 8080
