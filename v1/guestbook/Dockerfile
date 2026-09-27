FROM golang:1 AS builder
WORKDIR /app
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /app/guestbook .

FROM scratch
WORKDIR /app
COPY --from=builder /app/guestbook /app/guestbook
COPY public/index.html /app/public/index.html
COPY public/script.js /app/public/script.js
COPY public/style.css /app/public/style.css
USER 65532:65532
EXPOSE 3000
CMD ["/app/guestbook"]
