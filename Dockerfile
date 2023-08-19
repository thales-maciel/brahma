FROM debian:12

RUN apt-get update -y && apt-get install -y socat postgresql-client jq psmisc uuid-runtime bash

WORKDIR /app

COPY migrations ./migrations
COPY server.sh .

EXPOSE 80/tcp

CMD [ "./server.sh" ]
