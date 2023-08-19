#!/bin/bash

trap "exit" INT

export PORT="${PORT:-8080}"
export PGUSER="${DB_USER:-postgres}"
export PGHOST="${DB_HOST:-localhost}"
export PGPORT="${DB_PORT:-5432}"
export PGDATABASE="${DB_DB:-postgres}"
export PGPASSWORD="${DB_PASSWORD:-password}"

function log() {
    echo "$1" >&2
}

run_query() {
    local query="$1"
    local result=$(psql -t -A -c "$query" 2>&1)

    if [[ $result == *"ERROR:"* ]] || [[ $result == "psql: error"* ]]; then
        log "Query error: $result"
        return 1
    fi
    echo "$result"
}

run_migrations() {
  local migration_dir="./migrations"
  if [[ ! -d $migration_dir ]]; then
    echo "Migration directory not found!"
    return 1
  fi

  for sql_file in $(find $migration_dir -name "*.sql" | sort); do
    echo "Running migration: $sql_file"
    psql -t -q -A -f $sql_file 

    if [[ $? -ne 0 ]]; then
      echo "Error running migration: $sql_file"
      return 1
    fi
  done
  echo "Migrations completed successfully."
}

function handle_create() {
    local body="$1"
    local is_valid=$(echo $body | jq '. | if (.nome|type=="string") and (.apelido|type=="string") and (.nascimento|test("^\\d{4}-\\d{2}-\\d{2}$")) and ((.stack==null) or (.stack|type=="array" and all(.|type=="string"))) then 1 else 0 end')
    if [ "$is_valid" -eq 0 ]; then
        echo "HTTP/1.1 422 Unprocessable Entity\r\n\r\n" 
        return
    fi

    local uuid=$(uuidgen)
    local nome=$(echo "$body" | jq -r '.nome')
    local apelido=$(echo "$body" | jq -r '.apelido')
    local nascimento=$(echo "$body" | jq -r '.nascimento')
    local stack=$(echo "$body" | jq -r 'if .stack == null then "NULL" else .stack | join(",") | "'\''{\(.)}'\''" end')
    local query="PREPARE insert_person (uuid, text, text, date, text[]) AS INSERT INTO people (id, nome, apelido, nascimento, stack) VALUES (\$1, \$2, \$3, \$4, \$5); EXECUTE insert_person ('$uuid', '$nome', '$apelido', '$nascimento', $stack);"
    run_query "$query" 1>/dev/null

    local status="$?"
    if [ "$status" -eq 1 ] 2>/dev/null; then
        echo "HTTP/1.1 422 Unprocessable Entity\r\n\r\n" 
        return
    fi

    echo "HTTP/1.1 201 Created\r\nLocation: /pessoas/$uuid\r\n\r\n" 
}

function handle_get() {
    local path="$1"
    local id=$(echo $path | cut -d'/' -f 3-)

    local query="PREPARE get_person (uuid) AS SELECT json_build_object('id', id, 'nome', nome, 'apelido', apelido, 'nascimento', nascimento, 'stack', stack) FROM people where id = \$1; EXECUTE get_person ('$id');"
    local res=$(run_query "$query" | tail -n +2)
    if [ -z "$res" ]; then
        echo "HTTP/1.1 404 Not Found\r\n\r\n" 
        return
    fi

    echo "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n$res" 
}

function handle_count() {
    local query="SELECT count(1) FROM people"
    local res=$(run_query "$query")
    if [[ ! "$res" =~ ^[0-9]+$ ]]; then
        echo "HTTP/1.1 500 Internal Server Error\r\n\r\n" 
        return
    fi

    echo "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$res" 
}

function handle_search() {
    local path="$1"
    local term=$(echo $path | grep -oP 't=\K[^&]*')

    local query="PREPARE search_people (text) AS SELECT json_agg(json_build_object('id', id, 'nome', nome, 'apelido', apelido, 'nascimento', nascimento, 'stack', stack)) FROM people where for_search like ('%' || \$1 || '%') limit 50; EXECUTE search_people ('$term');"
    local res=$(run_query "$query" | tail -n +2)

    echo "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n$res" 
}

function handle_request() {
    while read line; do
        trline=`echo $line | tr -d '[\r\n]'`
        [ -z "$trline" ] && break

        CONTENT_LENGTH_REGEX='Content-Length:\s(.*?)'
        [[ "$trline" =~ $CONTENT_LENGTH_REGEX ]] &&
            CONTENT_LENGTH=`echo $trline | sed -E "s/$CONTENT_LENGTH_REGEX/\1/"`

        HEADLINE_REGEX='(.*?)\s(.*?)\sHTTP.*?'
        [[ "$trline" =~ $HEADLINE_REGEX ]] &&
            REQUEST=$(echo $trline | sed -E "s/$HEADLINE_REGEX/\1 \2/")
    done

    if [ ! -z "$CONTENT_LENGTH" ]; then
        read -n$CONTENT_LENGTH -t1 body;
    fi

    case "$REQUEST" in
        "GET /pessoas/"*) RESPONSE=$(handle_get "$REQUEST");;
        "GET /pessoas"*) RESPONSE=$(handle_search "$REQUEST");;
        "GET /contagem-pessoas") RESPONSE=$(handle_count);;
        "POST /pessoas") RESPONSE=$(handle_create "$body");;
        *) RESPONSE="HTTP/1.1 404 NotFound\r\n\r\n\r\nNot Found" ;;
    esac
    log "RESPONSE = $RESPONSE"
    echo -e "$RESPONSE"
}

if [ "$1" == "handle_request" ]; then
    handle_request
    exit
else
    run_migrations
    echo "Listening on $PORT"
    while true; do
        socat TCP-LISTEN:$PORT,reuseaddr EXEC:"$0 handle_request"
    done
fi
