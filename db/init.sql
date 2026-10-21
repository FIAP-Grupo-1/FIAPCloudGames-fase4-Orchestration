-- Cria os bancos de catalog e payments na primeira subida do Postgres.
-- O banco 'fcgdb' (users) ja nasce via POSTGRES_DB no docker-compose.
-- notifications NAO tem mais banco Postgres: a persistencia migrou para o
-- DynamoDB da funcao Lambda (ver FIAPCloudGames-fase3-NotificationsAPI).
CREATE DATABASE catalogdb;
CREATE DATABASE paymentsdb;
