FROM alpine:3.23

RUN apk update 
RUN apk add --no-cache redis
RUN echo 'vm.overcommit_memory = 1' | tee -a /etc/sysctl.conf

CMD ["sh", "-c", "exec redis-server --protected-mode no --port ${REDIS_PORT}"]