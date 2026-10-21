# FCG Orchestration (Fase 3)

Repositório de **orquestração** da FIAP Cloud Games (Fase 3). Parte da base da Fase 2 (RabbitMQ, PostgreSQL, `docker-compose` e manifestos Kubernetes) e concentra aqui as novas capacidades obrigatórias do Tech Challenge: **API Gateway (Kong)** (feito, cobrindo `users-api`, `catalog-api`, `payments-api` e, localmente, o `NotificationsAPI` -- ver [API Gateway (Kong)](#api-gateway-kong)), **Observabilidade (New Relic)**, **NoSQL (DynamoDB)**, **Redis** e a migração do `NotificationsAPI` para **Serverless (AWS Lambda)**.

> **Com pressa?** O gateway responde em `http://localhost:8000` (Docker) ou `http://gateway.fcg.local` (Kubernetes com Ingress). A tabela de [onde chamar o gateway](#onde-chamar-o-gateway) tem a URL base de cada forma de subir o projeto.

> Cada microsserviço vive no seu próprio repositório `FIAPCloudGames-fase3-*`, partindo do código da Fase 2 até que cada frente evolua o serviço correspondente.

## Stack escolhida pelo grupo

| Requisito obrigatório | Ferramenta escolhida | Onde vive |
|---|---|---|
| API Gateway | Kong | `Orchestration` (manifestos `k8s/`) |
| Migração para Serverless | AWS Lambda (SNS + SQS) | Repositório próprio `FIAPCloudGames-fase3-NotificationsAPI` |
| Observabilidade | New Relic (Opção B: métricas, logs e traces) | `UsersAPI`, `CatalogAPI`, `PaymentsAPI` e a função Lambda |
| NoSQL | DynamoDB (dados de notificação) | Função Lambda / `FIAPCloudGames-fase3-NotificationsAPI` |
| Cache distribuído | Redis | Microsserviço(s) HTTP |

## Arquitetura

3 microsserviços HTTP independentes que se comunicam de forma **assíncrona** (RabbitMQ entre `catalog-api` -> `payments-api`; SNS de `users-api`/`payments-api` para a Lambda de notificações), mais uma função serverless:

| Serviço | Papel | Banco | REST |
|---|---|:---:|:---:|
| users-api | Cadastro, login (JWT), autorização | PostgreSQL | Sim |
| catalog-api | CRUD de jogos, inicia compra, biblioteca | PostgreSQL + Redis (cache) | Sim |
| payments-api | Simula pagamento (consumidor de eventos) | PostgreSQL | Sim (consulta e disparo manual) |

O antigo `notifications-api` (container 24/7 que só consumia eventos do RabbitMQ) foi **migrado para uma função AWS Lambda**, e é assim que ele roda em produção. Localmente, o `docker-compose` e o `k8s` deste repositório rodam o mesmo código no emulador da Lambda, atrás do Kong, só para teste — ver [NotificationsAPI local (via Kong)](#notificationsapi-local-via-kong) e [Serverless (NotificationsAPI)](#serverless-notificationsapi).

Repos dos serviços:
- users-api: https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-UsersAPI
- catalog-api: https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-CatalogAPI
- payments-api: https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-PaymentsAPI
- notifications (serverless): https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-NotificationsAPI

> `FiapCloudGames.Contracts` (https://github.com/pdelfino0/fcg-contracts) é o pacote com as classes de evento compartilhadas entre os serviços. É consumido via **NuGet** (`PackageReference` no `.csproj` de cada serviço), **não** precisa ser clonado localmente para rodar o Compose ou o k8s.

## Estrutura

```
FIAPCloudGames-fase3-Orchestration/   # este repo (nome padrão do git clone)
├── docker-compose.yml   # RabbitMQ + Postgres (2 bancos) + Redis + 3 microsserviços HTTP + Kong
├── .env.example         # variáveis do Compose (sem valores reais)
├── db/init.sql          # cria catalogdb e paymentsdb
├── kong/                # API Gateway: config declarativa (única fonte de verdade)
│   ├── kong.yml             # services, routes, plugins e credencial JWT
│   └── render-and-start.sh  # injeta segredo/issuer e sobe o Kong
├── k8s/                 # manifestos agregados (kubectl apply -f k8s/)
├── notifications-local/ # NotificationsAPI só local: Dockerfile da Lambda + init do DynamoDB
├── observability/       # secret/manifestos de New Relic
├── docs/                # documentação de observabilidade
├── scripts/             # automação (k8s/, kong/ e validate-tracing.sh)
└── templates/           # modelos de Dockerfile e /k8s por serviço
```

## Pré-requisitos

Instale antes de começar:

| Ferramenta | Para quê | Obrigatório? |
|---|---|---|
| **Docker** + **Docker Compose** (plugin v2) | subir o stack | sim |
| **git** | clonar os 5 repositórios | sim |
| **jq** | os comandos de teste deste README extraem JSON com ele | sim (`apt install jq`) |
| **minikube** + **kubectl** | só para a rota Kubernetes | opcional |
| **AWS CLI** | só para inspecionar Lambda/DynamoDB na AWS | opcional |

Não é preciso ter .NET instalado: os serviços são compilados dentro do `docker build`.

```bash
docker --version && docker compose version && git --version && jq --version
```

## Como clonar (layout esperado)

Clone os **5 repos** na **mesma pasta pai**. O `docker-compose` assume os nomes padrão gerados pelo GitHub:

```
pasta-pai/
├── FIAPCloudGames-fase3-Orchestration/   # este repo
├── FIAPCloudGames-fase3-UsersAPI/
├── FIAPCloudGames-fase3-CatalogAPI/
├── FIAPCloudGames-fase3-PaymentsAPI/
└── FIAPCloudGames-fase3-NotificationsAPI/   # código + IaC da função Lambda (em produção roda na AWS; localmente, no emulador)
```

```bash
mkdir fcg-fase3 && cd fcg-fase3

git clone https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-Orchestration.git
git clone https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-UsersAPI.git
git clone https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-CatalogAPI.git
git clone https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-PaymentsAPI.git
git clone https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-NotificationsAPI.git
```

> Não é preciso clonar `fcg-contracts`: ele é restaurado como pacote NuGet durante o `dotnet restore`/`docker build` de cada serviço.

> Se você **renomeou** as pastas localmente (ex.: `fcg-users-api`), copie `.env.example` para `.env` e ajuste `USERS_API_PATH`, `CATALOG_API_PATH`, etc.

## Como rodar com Docker

Pré-requisito: os repos de serviço devem estar como **irmãos** deste, com os nomes padrão do clone (ou caminhos customizados no `.env`).

```bash
cd FIAPCloudGames-fase3-Orchestration
cp .env.example .env        # <- e PREENCHA as credenciais, ver abaixo
docker-compose up --build
docker-compose ps           # todos healthy/running; o notifications-dynamodb-init
                            # sai com Exited (0) de propósito: ele só cria a tabela
```

### O que preencher no `.env`

O `.env.example` já vem com tudo que é local (senhas de Postgres, RabbitMQ, Redis e o segredo
do JWT). **Três variáveis chegam vazias e precisam ser preenchidas** — sem elas o stack sobe,
mas duas frentes obrigatórias do Tech Challenge ficam mudas:

| Variável | Sem ela | Efeito prático |
|---|---|---|
| `NEW_RELIC_LICENSE_KEY` | Observabilidade morta | Os agentes sobem e não reportam nada: sem métricas, logs ou traces no New Relic |
| `AWS_ACCESS_KEY_ID` | Serverless mudo | O publish no SNS falha e o evento é **perdido**; a Lambda na AWS nunca é acionada |
| `AWS_SECRET_ACCESS_KEY` | idem | idem |

> ⚠️ **Sem as credenciais AWS, o cadastro (`POST /users/api/users/register`) leva ~16 segundos.**
> Não é lentidão da aplicação: sem credencial, o SDK da AWS percorre toda a cadeia de resolução
> (variáveis → perfil → **metadata do EC2**) e só desiste depois do timeout do último. Com as
> credenciais preenchidas, o mesmo cadastro responde em ~2s.

As três credenciais são fornecidas no documento de entrega, fora do repositório — nenhuma delas
é versionada aqui, como o enunciado exige.

### O catálogo nasce vazio

Não há seed de dados: logo após subir, `GET /catalog/api/v1/games` responde `"games":[]`. Isso é
esperado. Crie alguns jogos antes de testar o fluxo de compra:

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/users/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}' | jq -r .accessToken)

curl -s -X POST http://localhost:8000/catalog/api/v1/games \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Cyber Quest","description":"RPG futurista em Neo-Tokyo","price":99.90,"genre":1,"releaseDate":"2026-12-01"}'
```

> Duas validações do domínio que costumam surpreender: o **título precisa de ao menos 10
> caracteres** e a **data de lançamento não pode estar no passado** — as duas devolvem `400`.
> `genre` é o índice do enum: 0 Action, 1 RPG, 2 Strategy, 3 Sports, 4 Puzzle, 5 Other.

Portas locais: **gateway (Kong) `8000`**, users `8081`, catalog `8082`, payments `8083`, notifications `8084` (cadastro) e `8085` (pagamento) direto no emulador da Lambda (interno sempre `8080`).
Painel do RabbitMQ: http://localhost:15672 (fcg/fcg123).

> As portas diretas (8081-8085) continuam abertas para debug, mas o caminho "oficial" de `users`, `catalog`, `payments` e `notifications` agora é o gateway na `8000` -- ver [API Gateway (Kong)](#api-gateway-kong).

### Testar os fluxos

Tudo pelo gateway (`localhost:8000`):

```bash
# 1. Cadastro (rota anônima) -> publica UserRegisteredEvent no SNS (fcg-user-events),
#    acionando a Lambda de notificações na AWS
curl -s -X POST http://localhost:8000/users/api/users/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Teste","email":"teste@fcg.com","password":"Senha123!"}'

# 2. Login (rota anônima) -> guarda o token
TOKEN=$(curl -s -X POST http://localhost:8000/users/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}' | jq -r .accessToken)

# 3. Catálogo (rota protegida: o gateway valida o JWT antes de encaminhar)
curl -s http://localhost:8000/catalog/api/v1/games -H "Authorization: Bearer $TOKEN"
```

> O passo 1 requer `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` válidos no `.env`. Sem eles o cadastro **ainda funciona**, mas leva ~16s e o evento é perdido (a Lambda não é acionada) — ver [O que preencher no `.env`](#o-que-preencher-no-env).

4. **Compra:** iniciar compra no `catalog-api` pelo gateway -> `OrderPlacedEvent` via RabbitMQ -> `payments-api` processa e publica `PaymentProcessedEvent` em dois transportes: RabbitMQ (de volta pro `catalog-api`, libera o jogo na biblioteca se aprovado) e SNS (`fcg-payment-events`, aciona a Lambda de notificações).

5. **Notificações (só local):** os passos 1 e 4 publicam no SNS **da AWS**, então não acionam as funções que rodam aqui. Localmente, o NotificationsAPI é chamado pelas rotas `/notifications/...` do gateway — ver [Testando as notificações](#testando-as-notificações).

## Cache (Redis)

O `catalog-api` resolve as **leituras** de catálogo e de biblioteca por um cache Redis
(`RedisCacheService.GetOrSetAsync`): na primeira chamada vai ao Postgres e grava o
resultado; nas seguintes responde do cache até o TTL expirar.

| Rota | Chave | TTL |
|---|---|---|
| `GET /catalog/api/v1/games` | `games:all:page={p}:size={n}` | 3 min |
| `GET /catalog/api/v1/games/{id}` | `games:{id}` | 3 min |
| `GET /catalog/api/v1/library` | `libraries:all:userId={id}:page={p}:size={n}` | 3 min |

**O Redis não é opcional.** Sem a variável `ConnectionStrings__Redis` o serviço cai no
default do `appsettings.json` (`localhost:6379`), não acha ninguém e devolve **500 em
toda leitura** -- com o banco de pé, o gateway roteando certo e nenhum erro de config
aparente. Quem configura isso é este repo:

| Ambiente | Serviço Redis | Variável do catalog-api |
|---|---|---|
| Compose | serviço `redis` no `docker-compose.yml` | `ConnectionStrings__Redis` (montada de `REDIS_USER`/`REDIS_PASS`) |
| k8s | `k8s/12-redis.yaml` (Deployment + Service) | `ConnectionStrings__Redis` <- Secret `Catalog__RedisConnection` |

Nos dois casos a conexão usa um **usuário de ACL** (`fcg`), não `requirepass`: a
connection string do StackExchange.Redis manda `user=...,password=...`, e usuário
nomeado só existe via ACL. O usuário `default` fica desligado, então ninguém lê o
cache sem credencial. O `abortConnect=false` na string deixa o app subir mesmo com o
Redis ainda fora do ar.

O cache é **volátil de propósito** (sem PVC no k8s, sem volume no Compose, RDB e AOF
desligados): o conteúdo é descartável e se repopula na primeira leitura.

Inspecionar o cache:

```bash
# k8s
kubectl exec -n fcg deploy/redis -- \
  redis-cli --user fcg --pass fcg123 --no-auth-warning KEYS '*'

# Compose
docker-compose exec redis \
  redis-cli --user fcg --pass fcg123 --no-auth-warning KEYS '*'
```

> **Escrita não invalida a leitura.** Hoje o `catalog-api` só remove a chave `games:{id}`
> no update/delete de um jogo. Nada invalida as listas: comprar um jogo grava na
> biblioteca mas **não** apaga `libraries:all:userId=...`, então o `GET /library` continua
> devolvendo a biblioteca antiga por até 3 minutos após a compra. Mesma coisa para
> `games:all:...` após criar/apagar um jogo. É comportamento do `catalog-api`, não da
> orquestração -- ao testar o fluxo de compra, conte com essa janela.

## API Gateway (Kong)

Ponto de entrada único das APIs. Roda em modo **DB-less** (sem Postgres próprio): toda a configuração vem do arquivo declarativo `kong/kong.yml`.

**Escopo atual: `users-api`, `catalog-api`, `payments-api` e, só localmente, o `NotificationsAPI`.** Em produção o NotificationsAPI é uma função Lambda acionada por SQS, sem gatilho HTTP, e não passa por gateway. Localmente o mesmo código roda no emulador da Lambda e o Kong o invoca -- ver [NotificationsAPI local (via Kong)](#notificationsapi-local-via-kong).

`kong/kong.yml` é a **única fonte de verdade**: o `docker-compose` monta a pasta `kong/` como volume, e no Kubernetes o mesmo conteúdo é empacotado no ConfigMap `k8s/03-kong-config.yaml`, que é **gerado** por `make kong-config` (não edite o ConfigMap à mão).

### Onde chamar o gateway

O Kong sempre escuta na porta **8000** *dentro* da rede (do Compose ou do cluster). O que muda entre os ambientes é só como você alcança essa porta de fora:

| Como você subiu | URL base do gateway | Precisa de que |
|---|---|---|
| `docker-compose up` | `http://localhost:8000` | nada, a porta já é publicada |
| k8s + `port-forward` | `http://localhost:8000` | `kubectl port-forward service/kong-proxy 8000:8000 -n fcg` rodando em outro terminal |
| k8s + Ingress | `http://gateway.fcg.local` (porta 80) | `make k8s-ingress` + `minikube tunnel` + entrada no arquivo de hosts |

Trocar de ambiente é trocar só a URL base -- os caminhos (`/users/...`, `/catalog/...`) são idênticos nos três casos:

```bash
GATEWAY=http://localhost:8000          # Compose ou port-forward
# GATEWAY=http://gateway.fcg.local     # k8s com Ingress

curl -s -X POST $GATEWAY/users/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}'
```

### Rotas expostas

| Rota no gateway | Vai para | JWT no gateway |
|---|---|:---:|
| `POST /users/api/auth/login` | `users-api:8080/api/auth/login` | não (é ela que **emite** o token) |
| `POST /users/api/users/register` | `users-api:8080/api/users/register` | não (cadastro é anônimo) |
| `/users/**` (resto, hoje `/api/admin/users/**`) | `users-api:8080/**` | **sim** |
| `GET /catalog/swagger/...` | `catalog-api:8080/swagger/...` | não |
| `/catalog/**` (resto) | `catalog-api:8080/**` | **sim** |
| `GET /payments/health` | `payments-api:8080/health` | não |
| `POST /payments/process` | `payments-api:8080/payments/process` | **sim** (+ limite de 30 req/min) |
| `/payments/**` (resto: `GET /payments`, `/{id}`, `/by-event/{eventId}`) | `payments-api:8080/payments/**` | **sim** |
| `POST /notifications/user-registered` *(só local)* | `notifications-user-registered:8080/2015-03-31/functions/function/invocations` | **sim** |
| `POST /notifications/payment-processed` *(só local)* | `notifications-payment-processed:8080/2015-03-31/functions/function/invocations` | **sim** |

O `strip_path` do Kong remove o prefixo, então as rotas originais dos serviços continuam valendo:

```
GET  http://localhost:8000/catalog/api/v1/games      ->  GET  http://catalog-api:8080/api/v1/games
POST http://localhost:8000/users/api/users/register  ->  POST http://users-api:8080/api/users/register
```

**A postura é "nega por padrão".** As duas rotas anônimas do `users-api` são liberadas endpoint a endpoint *e por método* (`POST`/`OPTIONS`); qualquer outro caminho ou verbo cai na rota catch-all `/users`, que exige JWT. Um endpoint novo no `users-api` já nasce protegido no gateway, sem editar nada:

```bash
curl -i http://localhost:8000/users/api/admin/users        # 401 - catch-all pede token
curl -i -X GET http://localhost:8000/users/api/auth/login  # 401 - GET não está liberado, cai na catch-all
```

> O plugin `jwt` confere **assinatura, `exp` e issuer** -- não papel. O `AdminOnly` de `/api/admin/users/**` continua sendo decidido pelo `users-api`, que lê a claim de role do token.

<details>
<summary><b>Detalhe de implementação: por que há vários <code>services</code> do Kong por microsserviço</b></summary>

`strip_path: true` remove do upstream **todo o prefixo que a rota casou**, não apenas o primeiro segmento. Isso derruba a tentativa mais óbvia de liberar um endpoint específico:

```yaml
# ERRADO - verificado no Kong 3.9
- name: users-api
  url: http://users-api:8080
  routes:
    - name: users-login
      paths: [/users/api/auth/login]
      strip_path: true
# POST /users/api/auth/login  ->  POST /   (sobrou nada depois do strip)
```

A correção é pôr o caminho do upstream na **URL do service**; o que sobra do strip é concatenado depois:

```yaml
# CERTO
- name: users-api-login
  url: http://users-api:8080/api/auth/login   # <- caminho do upstream aqui
  routes:
    - name: users-login
      paths: [/users/api/auth/login]
      strip_path: true
# POST /users/api/auth/login  ->  POST /api/auth/login
```

Por isso um "service" do Kong aqui é um **endpoint de upstream**, não um microsserviço inteiro: `users-api-login`, `users-api-register` e `users-api` (catch-all) apontam todos para o mesmo host. A alternativa seria um plugin de rewrite (`request-transformer`) em cada rota -- mais peça móvel para o mesmo resultado.

Rotas de prefixo amplo (`/users`, `/catalog`) não sofrem disso: o strip deixa o resto do caminho intacto.

</details>

### Plugins habilitados

| Plugin | Escopo | Para que |
|---|---|---|
| `jwt` | rotas `/users/**` e `/catalog/**` | valida assinatura HS256, `exp` e o issuer do token |
| `rate-limiting` | rotas de login e register | **20 req/min e 200 req/h por IP** (anti brute-force) |
| `rate-limiting` | global | 120 req/min e 2000 req/h (`policy: local`) |
| `cors` | global | libera o consumo pelo front |
| `correlation-id` | global | gera/propaga `X-Correlation-ID` e devolve na resposta |
| `request-size-limiting` | global | corta payloads acima de 10 MB |
| `prometheus` | global | métricas em `:8100/metrics` (pronto para a frente de observabilidade) |

O Kong aplica **só a instância mais específica** de cada plugin (rota > serviço > global). Por isso o limite apertado das rotas de login/register *substitui* o global em vez de somar -- dá para ver nos headers da resposta:

```bash
curl -s -D - -o /dev/null -X POST http://localhost:8000/users/api/auth/login -d '{}' | grep -i ratelimit
#   X-RateLimit-Limit-Minute: 20     <- rota de login
curl -s -D - -o /dev/null http://localhost:8000/catalog/api/v1/games | grep -i ratelimit
#   X-RateLimit-Limit-Minute: 120    <- global
```

> `policy: local` conta por instância do Kong. Com 2 réplicas no k8s, o limite efetivo é ~2x o configurado. Trocar para `policy: redis` quando o Redis entrar no projeto.
>
> No k8s, o Kong só vê o IP real do cliente porque o Deployment define `KONG_TRUSTED_IPS` (faixas privadas) e `KONG_REAL_IP_HEADER=X-Forwarded-For`. Sem isso, o peer TCP seria sempre o pod do `ingress-nginx` e **todo o tráfego externo contaria como um único IP** -- um usuário esbarrando no limite do login derrubaria o login de todos. `KONG_REAL_IP_RECURSIVE` fica em `off` de propósito: assim vale a *última* entrada do `X-Forwarded-For` (a que o ingress acabou de acrescentar), e não um valor que o cliente possa falsificar.

### Autenticação: quem emite e quem valida

O **users-api emite** o JWT; o gateway apenas **valida** antes de encaminhar. O `catalog-api` continua validando o token por conta dele -- é defesa em profundidade, não substituição.

O Kong precisa saber **qual credencial** usar para checar a assinatura, e descobre isso pela claim `iss` do token.

Na Fase 2 o `JwtTokenService` do users-api montava o token **sem** issuer (`new JwtSecurityToken(claims:, expires:, signingCredentials:)`), então o gateway rejeitava tudo com `401 {"message":"No mandatory 'iss' in claims"}`. O users-api passou a emitir a claim; a mudança é retrocompatível, porque users-api e catalog-api usam `ValidateIssuer = false` e seguem ignorando o valor.

O issuer vem de **uma variável única**, lida pelos dois lados -- é o que impede os dois de dessincronizarem:

| Onde | Variável | Papel |
|---|---|---|
| users-api | `JwtSettings__Issuer` | **emite** a claim `iss` |
| kong | `JWT_ISSUER` | **valida** a claim `iss` |

Ambas saem de `JWT_ISSUER` (default `FCG`): do `.env` no Compose, da key `JWT_ISSUER` do ConfigMap `fcg-config` no k8s.

Para mudar o issuer, **não edite o `kong/kong.yml`** -- mexa só na variável:

```bash
# Compose: ajuste JWT_ISSUER no .env e recrie os dois
docker-compose up -d --force-recreate users-api kong

# k8s: ajuste a key JWT_ISSUER e reinicie os dois
kubectl apply -f k8s/01-configmap.yaml
kubectl rollout restart deployment/users-api deployment/kong -n fcg
```

Conferindo a claim de um token real:

```bash
echo "$TOKEN" | cut -d. -f2 | base64 -d 2>/dev/null | jq .iss    # "FCG"
```

> **Reiniciar só um dos dois quebra o login via gateway.** Se mudar `JWT_ISSUER` e reiniciar apenas o users-api (ou apenas o Kong), os tokens novos deixam de casar com a credencial do gateway e toda chamada autenticada volta `401 No credentials found for given 'iss'`.

### Onde fica o segredo

O `JWT_SECRET_KEY` (mesma chave HMAC de users e catalog) **não** está versionado no `kong/kong.yml` -- o arquivo traz o placeholder `__JWT_SECRET_KEY__`, que o `kong/render-and-start.sh` substitui na subida do container, lendo a variável de ambiente. A origem do valor depende do ambiente:

| Ambiente | De onde vem o segredo |
|---|---|
| Compose | `JWT_SECRET_KEY` no `.env` |
| Kubernetes | key `JwtSettings__SecretKey` do Secret `fcg-secrets` (`k8s/02-secret.yaml`) |

A key é a **mesma** que alimenta o `users-api` (que emite o token) e o `catalog-api` (que também valida): uma entrada no Secret, três consumidores. Trocar a chave é editar `k8s/02-secret.yaml` e reiniciar os três -- se reiniciar só parte deles, os tokens novos deixam de casar com quem ficou com a chave antiga:

```bash
kubectl apply -f k8s/02-secret.yaml
kubectl rollout restart deployment/users-api deployment/catalog-api deployment/kong -n fcg
```

Por que um script de render, e não interpolação: o Kong DB-less não expande variáveis de ambiente no YAML declarativo, e o campo `jwt_secrets.secret` não aceita referência de vault (`{vault://env/...}`) -- a referência seria usada como a própria chave HMAC e toda validação falharia com `Invalid signature`.

Cuidados que o `render-and-start.sh` toma com o valor (e o motivo de cada um):

| Cuidado | Por que |
|---|---|
| o valor vai por `ENVIRON` do `awk`, não por `awk -v` | `argv` é legível por qualquer processo do container via `ps`/`/proc` |
| `unset JWT_SECRET_KEY` antes do `exec` | tira o segredo de `/proc/1/environ`, visível a quem consiga um `kubectl exec` |
| arquivo renderizado criado com `umask 077` (fica `0600`) | ele contém o segredo em texto |
| substituição literal (`index`/`substr`) e valor emitido como escalar YAML entre aspas simples | segredo com `&`, `\|`, `"`, `\` ou `$` corromperia um `sed` ou o YAML, gerando uma chave HMAC silenciosamente errada |

No k8s, a **Admin API escuta apenas em `127.0.0.1`** dentro do pod (`KONG_ADMIN_LISTEN`), porque ela devolve a credencial já resolvida:

```bash
kubectl port-forward deploy/kong 8001:8001 -n fcg     # em outro terminal
curl -s localhost:8001/consumers/fcg-users-api/jwt | jq '.data[0]'
#   ...,"key":"FCG","secret":"6a8a56f4..."     <- o segredo, em texto
```

Sem esse bind, qualquer pod do cluster leria o segredo do JWT com um `curl`. O `port-forward` continua funcionando porque ele entra na **network namespace do pod** e disca o `127.0.0.1` de dentro dele -- e por isso a Admin API segue acessível para quem já tem credencial no cluster, e só para essa pessoa.

### Testando o gateway

Trocando `GATEWAY` conforme a tabela de [onde chamar o gateway](#onde-chamar-o-gateway), o roteiro é o mesmo nos três ambientes:

```bash
GATEWAY=http://localhost:8000

# 0. O gateway carregou a config declarativa?
#    (Compose: porta já publicada. k8s: kubectl port-forward service/kong-proxy 8100:8100 -n fcg)
curl -s http://localhost:8100/status/ready     # {"message":"ready"}

# 1. Cadastro e login: rotas ANÔNIMAS no gateway
curl -s -X POST $GATEWAY/users/api/users/register -H "Content-Type: application/json" \
  -d '{"name":"Teste","email":"teste@fcg.com","password":"Senha123!"}'

TOKEN=$(curl -s -X POST $GATEWAY/users/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}' | jq -r .accessToken)

# 2. Rota protegida COM token
curl -i $GATEWAY/catalog/api/v1/games -H "Authorization: Bearer $TOKEN"
curl -i $GATEWAY/users/api/admin/users -H "Authorization: Bearer $TOKEN"

# 3. Sem token: o gateway barra antes de encostar no serviço
curl -i $GATEWAY/catalog/api/v1/games      # 401 {"message":"Unauthorized"}
curl -i $GATEWAY/users/api/admin/users     # 401 {"message":"Unauthorized"}
```

> No passo 2, `/users/api/admin/users` com o token de um usuário recém-cadastrado responde **403**: o gateway aprovou o token (assinatura e `exp` válidos) e o `users-api` recusou o papel. Um 403 ali é sinal de que o gateway fez a parte dele -- diferente do 401, que nem sai do Kong.

Comportamento do plugin `jwt` (verificado no Kong 3.9 com tokens forjados):

| Requisição | Resposta do gateway |
|---|---|
| sem `Authorization` | `401 {"message":"Unauthorized"}` |
| assinado com outro segredo | `401 {"message":"Invalid signature"}` |
| `iss` diferente do configurado | `401 {"message":"No credentials found for given 'iss'"}` |
| `exp` no passado | `401 {"exp":"token expired"}` |
| token válido | encaminhado ao serviço |

E o roteamento (o que o serviço realmente recebe):

| Chamada no gateway | Chega no upstream como |
|---|---|
| `POST /users/api/auth/login` | `POST users-api:8080/api/auth/login` |
| `POST /users/api/users/register` | `POST users-api:8080/api/users/register` |
| `GET /users/api/admin/users` | `GET users-api:8080/api/admin/users` |
| `GET /catalog/api/v1/games` | `GET catalog-api:8080/api/v1/games` |
| `GET /catalog/swagger/index.html` | `GET catalog-api:8080/swagger/index.html` |
| `GET /payments/health` | `GET payments-api:8080/health` |
| `GET /payments` | `GET payments-api:8080/payments` (sem strip -- ver abaixo) |
| `GET /payments/by-event/{eventId}` | `GET payments-api:8080/payments/by-event/{eventId}` |

> **Por que o `/payments` não usa `strip_path`.** Em `users` e `catalog` o prefixo do gateway não existe no serviço, então precisa sair. No `payments-api` é o contrário: o controller já vive em `/payments`, o mesmo prefixo do gateway. Com `strip_path: true` a catch-all mandaria `GET /payments` como `GET /` e o serviço responderia 404. Por isso ela usa `strip_path: false` e repassa o caminho inteiro. O `/payments/health` segue a regra geral (caminho na URL do service), porque no serviço o health vive na raiz.

> **Limite de autorização do `payments-api`.** Nenhum endpoint do serviço tem `[Authorize]` -- ele nasceu como consumidor de evento e a API REST veio depois, para demonstração. Aqui o gateway é a **única** camada de autenticação (users e catalog validam o token de novo por conta própria). E ela confere assinatura e `exp`, não papel: `GET /payments` lista os pagamentos de **todos** os usuários, e qualquer usuário autenticado consegue lê-los. Fechar isso exige um `AdminOnly` no próprio `payments-api`, como o `users-api` faz em `/api/admin/users/**`.

> **Swagger:** os dois serviços registram o Swagger apenas quando `ASPNETCORE_ENVIRONMENT=Development` (`if (app.Environment.IsDevelopment())` no `Program.cs`). Compose e k8s rodam em `Production`, então `/catalog/swagger` responde **404 vindo do serviço** -- a rota do gateway está certa, o Swagger é que não existe naquele ambiente. Para explorar o contrato, suba o serviço com `ASPNETCORE_ENVIRONMENT=Development` e use a porta direta (`http://localhost:8082/swagger`): o `swagger.json` gerado pelo ASP.NET aponta para o caminho absoluto `/swagger/v1/swagger.json`, sem o prefixo `/catalog`, então o "Try it out" pelo gateway não carregaria o schema.

### Portas do gateway

| Porta | O que é | Exposição no Compose | Exposição no k8s |
|---|---|---|---|
| `8000` | proxy (entrada das APIs) | `0.0.0.0` | Service `kong-proxy` + Ingress |
| `8001` | Admin API (read-only no DB-less) | só `127.0.0.1` do host | só `127.0.0.1` do **pod** |
| `8100` | `/status/ready` e `/metrics` | só `127.0.0.1` do host | Service `kong-proxy` (fora do Ingress) |

```bash
# Compose
curl -s http://localhost:8001/routes | jq '.data[].paths'   # rotas carregadas
curl -s http://localhost:8100/metrics | grep kong_http_requests_total

# k8s: a 8001 não sai do pod, então vá por port-forward (em outro terminal)
kubectl port-forward deploy/kong 8001:8001 -n fcg
curl -s http://localhost:8001/routes | jq '.data[].paths'
```

> Não tente `kubectl exec ... -- curl`: a imagem `kong:3.9` **não traz `curl` nem `wget`** (só `perl` e `resty`). Para inspecionar o gateway de fora, use `port-forward`.

> No Compose a Admin API escuta em `0.0.0.0` de propósito: o mapeamento de portas do Docker chega pelo IP do container, então com bind no loopback a publicação não funcionaria. Quem limita o acesso ali é a própria publicação, presa em `127.0.0.1` do host.

### No Kubernetes

O Kong sobe como `Deployment` (2 réplicas) + `Service` ClusterIP `kong-proxy`, e o Ingress ganhou o host `gateway.fcg.local`:

```bash
make kong-config     # se editou kong/kong.yml (o make k8s-deploy tambem faz isso)
make k8s-deploy
make k8s-ingress     # exige o passo do minikube tunnel + arquivo de hosts

curl http://gateway.fcg.local/catalog/api/v1/games -H "Authorization: Bearer $TOKEN"
```

Sem Ingress, via port-forward (deixe rodando em outro terminal):

```bash
kubectl port-forward service/kong-proxy 8000:8000 -n fcg
# agora o gateway responde em http://localhost:8000, com os mesmos caminhos
```

> **Editou `kong/kong.yml`? O `make k8s-deploy` cuida do rollout.** O Kong lê a config declarativa **uma vez, no startup** -- trocar o ConfigMap não afeta os pods que já estão rodando. Para resolver isso, o `make kong-config` grava o hash das fontes numa annotation do ConfigMap e o `scripts/k8s/deploy.sh` copia esse hash para o pod template do Deployment. Como o `kubectl patch` é idempotente, os pods rolam quando (e somente quando) a config muda. Se aplicar os manifestos na mão, o restart é por sua conta:
>
> ```bash
> kubectl rollout restart deployment/kong -n fcg
> ```

### Adicionando um serviço novo ao gateway

Em `kong/kong.yml`, dois blocos em `services`: a catch-all protegida e uma liberação por endpoint, se houver rota anônima.

```yaml
  # 1) Endpoint anônimo: o caminho do upstream vai na URL DO SERVICE.
  #    (Não ponha o caminho completo só na rota com strip_path -- o strip
  #     removeria o caminho inteiro e o upstream receberia "/".)
  - name: novo-api-publico
    url: http://novo-api:8080/api/publico
    routes:
      - name: novo-publico
        paths: [/novo/api/publico]
        strip_path: true
        methods: [POST, OPTIONS]        # só este verbo passa sem token

  # 2) Catch-all: tudo o mais do prefixo /novo exige JWT.
  - name: novo-api
    url: http://novo-api:8080
    routes:
      - name: novo-protegido
        paths: [/novo]
        strip_path: true
        plugins:
          - name: jwt
            config: { key_claim_name: iss, claims_to_verify: [exp] }
```

Depois: `make kong-config` + `make k8s-deploy` (k8s) ou `docker-compose up -d --force-recreate kong` (Compose).

Vale conferir o roteamento no log do Kong -- ele mostra a URL exata que foi para o upstream:

```bash
docker-compose logs kong | grep upstream       # Compose
kubectl logs -n fcg deploy/kong | grep upstream  # k8s
```

## Como fazer deploy no Kubernetes (Minikube)

### Opção automatizada (recomendada)

Requisitos: `docker`, `minikube`, `kubectl` e `make` instalados. No Windows, rode via **Git Bash** ou **WSL** (o `make` não existe no PowerShell puro).

```bash
cp .env.example .env   # se ainda não fez isso para o Compose

make k8s-up            # start do Minikube + build/load das 4 imagens + apply + espera os pods ficarem prontos
make k8s-status        # ve pods, deployments, services, configmaps e secrets
make k8s-ingress       # (opcional) habilita o Ingress e aplica o manifesto de ingress
make k8s-down          # derruba tudo (remove o namespace fcg)
```

`make help` lista todos os comandos disponíveis. Os scripts usados pelo Makefile ficam em `scripts/k8s/` e leem os caminhos dos repos irmãos do `.env` (mesmas variáveis do Compose: `USERS_API_PATH`, `NOTIFICATIONS_API_PATH`, etc.). As 4 imagens são as das três APIs e a da Lambda local do NotificationsAPI — ver [NotificationsAPI local (via Kong)](#notificationsapi-local-via-kong).

O `minikube tunnel` e a edição do arquivo de hosts (necessários só para o Ingress) continuam manuais — ver o passo a passo abaixo.

### Passo a passo manual (o que o `make k8s-up` automatiza)

**1. Cluster**

```bash
minikube start
```

**2. Build + carga das 4 imagens no cluster local** (ajuste os caminhos se renomeou as pastas após o clone)

```bash
docker build -t fcg/users-api:1.0 ../FIAPCloudGames-fase3-UsersAPI -f ../FIAPCloudGames-fase3-UsersAPI/src/FCG.API/Dockerfile
minikube image load fcg/users-api:1.0
docker build -t fcg/catalog-api:1.0 ../FIAPCloudGames-fase3-CatalogAPI -f ../FIAPCloudGames-fase3-CatalogAPI/src/CatalogAPI.API/Dockerfile
minikube image load fcg/catalog-api:1.0
docker build -t fcg/payments-api:1.0 ../FIAPCloudGames-fase3-PaymentsAPI -f ../FIAPCloudGames-fase3-PaymentsAPI/src/FCG.API/Dockerfile
minikube image load fcg/payments-api:1.0

# NotificationsAPI (só local): o Dockerfile mora neste repo, em notifications-local/,
# e o código do repo irmão entra no build como contexto nomeado, só leitura
docker build --build-context notificationsapi=../FIAPCloudGames-fase3-NotificationsAPI/NotificationsAPI \
  -t fcg/notifications-lambda:1.0 notifications-local
minikube image load fcg/notifications-lambda:1.0
```

> O Kong (`kong:3.9`), o DynamoDB Local (`amazon/dynamodb-local`) e o AWS CLI que cria a tabela (`amazon/aws-cli`) não entram aqui: são imagens oficiais, baixadas do Docker Hub pelo próprio cluster.
>
> Rebuildou uma imagem que **já está rodando** no cluster? O `minikube image load` não troca a tag de uma imagem em uso e ainda assim termina com sucesso — o `make k8s-build` detecta isso e rola os Deployments; na mão, escale o Deployment para 0 antes do `load` (ver o troubleshooting do `401 ... 'iss'`).

**3. Regerar o ConfigMap do gateway** (só é obrigatório se você editou `kong/kong.yml`; o arquivo gerado está versionado)

```bash
bash scripts/kong/sync-configmap.sh    # o mesmo que `make kong-config`
```

**4. Aplicar os manifestos** (a numeração dos arquivos garante a ordem)

Antes, crie o ConfigMap com o script que cria a tabela do NotificationsAPI. Ele **não** está em `k8s/`: é gerado do arquivo `notifications-local/init-dynamodb.sh`, para não existir uma cópia colada no manifesto. Sem ele, o pod `notifications-dynamodb` fica preso em `ContainerCreating`.

```bash
kubectl apply -f k8s/00-namespace.yaml     # o ConfigMap precisa do namespace
kubectl create configmap notifications-dynamodb-init -n fcg \
  --from-file=init-dynamodb.sh=notifications-local/init-dynamodb.sh \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/

# Se o ConfigMap do Kong mudou no passo 3, force o rollout:
# o Kong lê a config declarativa uma vez, no startup.
kubectl rollout restart deployment/kong -n fcg

# Idem se você editou notifications-local/init-dynamodb.sh: o script só roda na subida do pod.
kubectl rollout restart deployment/notifications-dynamodb -n fcg
```

**5. Verificar**

```bash
kubectl get pods -n fcg
kubectl get deployments,services,configmaps,secrets -n fcg
kubectl rollout status deployment/kong -n fcg

# NotificationsAPI (só local)
kubectl rollout status deployment/notifications-dynamodb -n fcg       # 2/2: DynamoDB + init da tabela
kubectl rollout status deployment/notifications-user-registered -n fcg
kubectl rollout status deployment/notifications-payment-processed -n fcg

# a tabela existe? (esperado: ACTIVE)
kubectl exec -n fcg deploy/notifications-dynamodb -c init-table -- \
  aws dynamodb describe-table --table-name fcg-notifications \
  --endpoint-url http://localhost:8000 --query Table.TableStatus --output text
```

**6. Onde fazer as requisições**

Nada no cluster é alcançável do seu terminal por padrão: os Services são `ClusterIP`, ou seja, só existem dentro do cluster. Você precisa escolher **uma** das duas pontes abaixo.

**Opção A -- `port-forward` no gateway (mais rápido; é o que responde a pergunta "onde chamo o Kong?")**

Em um terminal separado, deixe rodando:

```bash
kubectl port-forward service/kong-proxy 8000:8000 -n fcg
```

Enquanto ele estiver de pé, **o gateway atende em `http://localhost:8000`** -- exatamente a mesma URL do Docker Compose:

```bash
GATEWAY=http://localhost:8000

# cadastro e login (rotas anônimas no gateway)
curl -s -X POST $GATEWAY/users/api/users/register -H "Content-Type: application/json" \
  -d '{"name":"Teste","email":"teste@fcg.com","password":"Senha123!"}'

TOKEN=$(curl -s -X POST $GATEWAY/users/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}' | jq -r .accessToken)

# rota protegida: o Kong valida o JWT antes de encaminhar
curl -i $GATEWAY/catalog/api/v1/games -H "Authorization: Bearer $TOKEN"

# sem token o gateway barra (401), sem nem encostar no serviço
curl -i $GATEWAY/catalog/api/v1/games

# notificações (só local): invoca a função do NotificationsAPI pelo gateway
curl -s -X POST $GATEWAY/notifications/user-registered \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"UserId":"11111111-1111-1111-1111-111111111111","Name":"Ana","Email":"ana@exemplo.com","EventId":"22222222-2222-2222-2222-222222222222","OccurredAt":"2026-09-10T12:00:00Z"}'
# {"batchItemFailures":[]}   -- mais exemplos em "Testando as notificações"
```

**Opção B -- Ingress**, se você quiser as URLs com hostname (`http://gateway.fcg.local`, sem porta): ver [Expor as APIs com Ingress](#expor-as-apis-com-ingress-alternativa-ao-port-forward). Exige `minikube tunnel` e uma entrada no arquivo de hosts.

Para debug, o `port-forward` também serve para bater direto em um serviço, **desviando do gateway** (sem JWT do Kong, sem rate-limit):

```bash
kubectl port-forward service/users-api 8081:8080 -n fcg     # http://localhost:8081/api/auth/login
kubectl port-forward service/catalog-api 8082:8080 -n fcg   # http://localhost:8082/api/v1/games
kubectl port-forward service/payments-api 8083:8080 -n fcg  # http://localhost:8083/health
kubectl port-forward service/notifications-user-registered 8084:8080 -n fcg     # emulador da Lambda (ver nota)
kubectl port-forward service/notifications-payment-processed 8085:8080 -n fcg   # idem
kubectl port-forward service/kong-proxy 8100:8100 -n fcg    # http://localhost:8100/status/ready e /metrics
```

> Direto no emulador da Lambda não há Kong: o endpoint é `POST http://localhost:8084/2015-03-31/functions/function/invocations` e o corpo tem de ser o **envelope SQS** (`{"Records":[...]}`, como os `events/*.json` do repo do NotificationsAPI) — é o gateway que embrulha o evento puro. Sem o envelope a resposta é HTTP 200 com `NullReferenceException` no corpo (ver [troubleshooting](#nullreferenceexception-chamando-o-emulador-da-lambda-direto)).

> Cada `port-forward` ocupa um terminal e cuida de **um** Service. É normal ter dois ou três abertos ao mesmo tempo (um por porta local).

## Expor as APIs com Ingress (alternativa ao port-forward)

O `port-forward` é só para teste manual (uma porta, um serviço, uma sessão). Para expor **todas** as APIs de uma vez, com um único ponto de entrada, usamos um `Ingress` (`k8s/30-ingress.yaml`), que roteia por hostname para cada Service.

> **Kong.** O API Gateway (validação de JWT + roteamento para `users-api`/`catalog-api`/`payments-api` e, localmente, as funções do NotificationsAPI) tem manifestos próprios (`k8s/03-kong-config.yaml`, `k8s/24-kong.yaml`, `kong/kong.yml`) e um host dedicado no Ingress (`gateway.fcg.local`, ver tabela abaixo). Ele é o caminho **oficial** de entrada; o Ingress nginx com um host por serviço, descrito a seguir, continua existindo como atalho de debug.

```bash
# 1. Habilitar o controller de Ingress do Minikube (só uma vez por cluster)
minikube addons enable ingress

# 2. Esperar o controller ficar Running (pode levar ~1 min)
kubectl get pods -n ingress-nginx --watch

# 3. Aplicar o manifesto do Ingress (se já rodou "kubectl apply -f k8s/" antes, só isso já basta)
kubectl apply -f k8s/30-ingress.yaml

# 4. Confirmar que o Ingress recebeu um endereço
kubectl get ingress -n fcg
```

Depois, em outro terminal (deixe rodando, exige permissão de administrador no Windows):

```bash
minikube tunnel
```

Isso expõe o controller do Ingress em `localhost:80`. Falta só resolver os hostnames: edite o arquivo de hosts do Windows (`C:\Windows\System32\drivers\etc\hosts`, como administrador) e adicione:

```
127.0.0.1 gateway.fcg.local
127.0.0.1 users.fcg.local
127.0.0.1 catalog.fcg.local
127.0.0.1 payments.fcg.local
127.0.0.1 rabbitmq.fcg.local
```

Agora cada API responde no seu hostname, na porta 80 (sem porta na URL). São **duas portas de entrada diferentes**, e é importante não confundir:

| Hostname | O que é | Rotas |
|---|---|---|
| `gateway.fcg.local` | **o API Gateway (Kong)** -- caminho oficial | `/users/...`, `/catalog/...`, `/payments/...`, `/notifications/...` (com prefixo) |
| `users.fcg.local`, `catalog.fcg.local`, ... | atalho direto pro Service, **desviando do gateway** | rotas originais, sem prefixo |

Pelo gateway (com JWT, rate-limit e correlation-id):

```bash
GATEWAY=http://gateway.fcg.local

TOKEN=$(curl -s -X POST $GATEWAY/users/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"ingress@teste.com","password":"Senha123!"}' | jq -r .accessToken)

curl $GATEWAY/catalog/api/v1/games -H "Authorization: Bearer $TOKEN"
```

Direto no serviço (útil para debug -- repare que **não** tem o prefixo `/users`):

```bash
curl -X POST http://users.fcg.local/api/users/register \
  -H "Content-Type: application/json" \
  -d '{"name":"Teste Ingress","email":"ingress@teste.com","password":"Senha123!"}'

curl http://catalog.fcg.local/api/v1/games
```

O painel de gestão do RabbitMQ também sai pelo mesmo túnel, em `http://rabbitmq.fcg.local` (login `fcg` / `fcg123`).

> **Por que por hostname e não por caminho (`/users`, `/catalog`)?** Cada API já tem seus próprios prefixos de rota (`/api/users/...`, `/api/v1/games`, etc.), diferentes entre si. Rotear por path exigiria reescrever a URL antes de repassar pro serviço (`rewrite-target`), o que complica sem necessidade aqui. Rotear por hostname mantém as rotas originais intactas — cada domínio aponta pra um Service só.
>
> Esse roteamento por path é justamente o que o **Kong** faz em `gateway.fcg.local/catalog/...`: o `strip_path` da rota remove o prefixo antes de repassar. O Ingress continua sendo só a porta de entrada do cluster — quem decide rota, autentica e aplica rate-limit é o gateway.

## Troubleshooting

### `401 {"message":"No mandatory 'iss' in claims"}` chamando o gateway

O token que você mandou não tem a claim `iss`, e o plugin `jwt` do Kong precisa dela para saber **qual credencial** usar. Quase sempre a causa não está no Kong nem no código, e sim no **pod rodando um build antigo do `users-api`**, anterior a claim existir.

Confirme comparando a imagem do host com a que está dentro do cluster:

```bash
docker images --no-trunc --format '{{.ID}}' fcg/users-api:1.0
minikube ssh -- "docker images --no-trunc --format '{{.ID}}' fcg/users-api:1.0"
```

Se os IDs divergirem, o cluster está com código velho. E se quiser a prova direta:

```bash
# a imagem que o pod REALMENTE roda tem a key Issuer?
minikube ssh -- "docker run --rm --entrypoint cat fcg/users-api:1.0 /app/appsettings.json" | grep -A4 JwtSettings

# e as claims de um token de verdade
echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq .iss    # esperado: "FCG"
```

Correção: `make k8s-build` (o script detecta a divergência, troca a imagem e sobe os pods de novo).

> **Por que isso acontece:** `minikube image load fcg/users-api:1.0` **não sobrescreve** uma tag que já existe no cluster quando um container está usando aquela imagem -- e termina com **código de sucesso**, sem aviso. Somado ao `imagePullPolicy: IfNotPresent` e a uma tag fixa (`:1.0`), o `kubectl apply` também não muda o pod spec, então não há rollout: o cluster fica rodando código antigo indefinidamente enquanto tudo aparenta ter funcionado.
>
> O `scripts/k8s/build-images.sh` cobre isso: compara o ID da imagem no host com o do cluster e, quando divergem, escala o Deployment para 0 (a tag só pode ser trocada quando nenhum container a usa), troca a imagem e volta as réplicas. No fim ele reconfere as quatro imagens e **falha** se alguma ficou defasada.

### `make k8s-build` avisa `[skip] Dockerfile nao encontrado`

O repo daquele serviço foi reestruturado e não tem mais o Dockerfile no caminho esperado. O script segue com os outros serviços e o cluster continua com a imagem de um build anterior -- o que roda, mas com código velho. Ajuste o caminho em `scripts/k8s/build-images.sh` (e no `docker-compose.yml`) quando o repo definir o novo layout.

Para a imagem local do NotificationsAPI o aviso é outro — `[skip] codigo-fonte nao encontrado em .../NotificationsAPI` —, porque o Dockerfile mora neste repo e o que falta é o **repo irmão**: clone-o ao lado deste ou ajuste `NOTIFICATIONS_API_PATH` no `.env`.

### `401 {"message":"Unauthorized"}` numa rota que deveria ser anônima

Confira o **método**. As rotas de login e register são liberadas só para `POST`/`OPTIONS`; qualquer outro verbo cai na catch-all `/users`, que exige JWT. Ver [Rotas expostas](#rotas-expostas).

### `401 No credentials found for given 'iss'`

O token tem `iss`, mas com valor diferente do que o gateway espera. Os dois lados leem a mesma variável `JWT_ISSUER` -- reinicie **os dois** após mudar (ver [Autenticação: quem emite e quem valida](#autenticação-quem-emite-e-quem-valida)).

### Editei `kong/kong.yml` e nada mudou

O Kong lê a config declarativa uma vez, no startup. Rode `make k8s-deploy` (que propaga o hash e rola o gateway) ou `kubectl rollout restart deployment/kong -n fcg`.

### `500 Erro interno` em `/catalog/api/v1/games` ou `/catalog/api/v1/library`

Falta o Redis. Nos logs do pod aparece `StackExchange.Redis.RedisConnectionException:
UnableToConnect ... on localhost:6379` — o `localhost` entrega o diagnóstico: o serviço
não recebeu `ConnectionStrings__Redis` e caiu no default do `appsettings.json`. Confira:

```bash
kubectl get pods -n fcg -l app=redis                       # o Redis subiu?
kubectl get deploy catalog-api -n fcg -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' | tr ' ' '\n' | grep Redis
```

Se a variável não aparecer, o Deployment está defasado em relação a `k8s/21-catalog-api.yaml`
— rode `make k8s-deploy`. Ver [Cache (Redis)](#cache-redis).

### Comprei um jogo, veio `202`, mas a biblioteca continua vazia

Se os logs do `payments-api` mostram `Pagamento processado ... Approved` e o `catalog-api`
registra o `PaymentProcessedEventHandler`, o fluxo funcionou e o que você está lendo é o
**cache**: o `GET /library` foi cacheado (3 min) antes da compra e nada o invalida. Para
confirmar, leia com outro `pageSize` (chave de cache diferente, vai ao banco):

```bash
curl -s "$GATEWAY/catalog/api/v1/library/?page=1&pageSize=19" -H "Authorization: Bearer $TOKEN"
```

Ver a nota em [Cache (Redis)](#cache-redis). Se o `catalog-api` estiver em loop de
`ACCESS_REFUSED`, aí sim o evento nunca saiu: o Deployment não está injetando
`RabbitMq__Username`/`RabbitMq__Password` e o app usa o `guest`/`pass` do `appsettings.json`.

### Pod `notifications-dynamodb` preso em `ContainerCreating`

O pod monta o script de criação da tabela a partir do ConfigMap `notifications-dynamodb-init`, que **não** está em `k8s/`: ele é gerado do arquivo pelo `make k8s-deploy`. Aplicar os manifestos na mão sem o passo 4 do [Passo a passo manual](#passo-a-passo-manual-o-que-o-make-k8s-up-automatiza) deixa o pod preso, com este evento:

```bash
kubectl describe pod -n fcg -l app=notifications-dynamodb | grep -i configmap
# MountVolume.SetUp failed for volume "init" : configmap "notifications-dynamodb-init" not found
```

Crie o ConfigMap (passo 4) e o kubelet monta o volume na próxima tentativa, sem precisar recriar o pod.

### Notificação falha com `ResourceNotFoundException` (tabela inexistente)

A resposta traz o item em `batchItemFailures` e o log da função mostra:

```
Falha ao processar mensagem ..., será reenfileirada Amazon.DynamoDBv2.Model.ResourceNotFoundException: Cannot do operations on a non-existent table
```

O DynamoDB Local roda em memória: se ele reinicia, a tabela some, e o script que a cria só roda na subida.

- **Compose:** o `notifications-dynamodb-init` já saiu. Rode-o de novo com `docker-compose up -d notifications-dynamodb-init`.
- **k8s:** o container `init-table` segue de pé, mas a readiness dele passa a falhar e o pod sai do Service. Recrie o pod com `kubectl rollout restart deployment/notifications-dynamodb -n fcg`.

### `NullReferenceException` chamando o emulador da Lambda direto

Chamando a porta direta do emulador (`8084`/`8085`, sem o gateway), a resposta vem com **HTTP 200** e o erro no corpo:

```
{"errorType": "NullReferenceException", "errorMessage": "Object reference not set to an instance of an object.", ...}
```

O corpo não era o envelope SQS. Sem `Records`, a função quebra na primeira linha do `SqsBatchProcessor`. O emulador, como a própria Lambda, devolve o erro da função no **corpo**, não no status HTTP. Mande o envelope (`{"Records":[...]}`, como os `events/*.json` do repo do NotificationsAPI) ou passe pelo gateway, que embrulha o evento puro.

### Notificação responde `batchItemFailures` vazio, mas nada foi gravado

Não é falha: a função descartou a mensagem de propósito, porque na AWS reentregá-la não adiantaria. O log diz o motivo:

```bash
docker-compose logs notifications-user-registered | grep -E "malformada|já processada"            # Compose
kubectl logs -n fcg deploy/notifications-user-registered | grep -E "malformada|já processada"     # k8s
```

- `Mensagem ... malformada, descartando`: o `body` não é um JSON válido do evento, por exemplo um `UserId` que não é GUID.
- `Mensagem ... já processada anteriormente, descartando reentrega`: o `EventId` já está na tabela. Gere outro `EventId` para repetir o teste.

## NotificationsAPI local (via Kong)

Em **produção** o `NotificationsAPI` é uma função AWS Lambda acionada por SQS (ver [Serverless (NotificationsAPI)](#serverless-notificationsapi)): não tem entrada HTTP e não passa pelo gateway. Para quem está **testando localmente**, este repositório roda o **mesmo código** na imagem oficial da Lambda (`public.ecr.aws/lambda/dotnet:10`), que já traz o *Runtime Interface Emulator* — um endpoint HTTP de invocação — e o Kong expõe esse endpoint. Vale para Compose e Minikube, com os mesmos caminhos.

```
                                       Kong (JWT + envelope SQS)
POST /notifications/user-registered   ─▶ notifications-user-registered   ─┐
POST /notifications/payment-processed ─▶ notifications-payment-processed ─┴─▶ DynamoDB Local
                                         (emulador da Lambda, :8080)         (fcg-notifications)
```

**Nada disso toca a produção.** Nenhum arquivo do repositório do NotificationsAPI é alterado: o `Dockerfile` e o script da tabela moram aqui, em `notifications-local/`, e o código entra no build como contexto nomeado, só leitura. `template.yaml`, `samconfig.toml` e o `sam deploy` seguem iguais; a imagem local nunca é publicada; e as funções locais usam credenciais AWS fictícias e o DynamoDB Local, sem nunca enxergar as chaves reais do `.env`.

| Peça | Compose | k8s |
|---|---|---|
| Função de cadastro | serviço `notifications-user-registered` (porta direta `8084`) | Deployment `notifications-user-registered` |
| Função de pagamento | serviço `notifications-payment-processed` (porta direta `8085`) | Deployment `notifications-payment-processed` |
| DynamoDB Local | serviço `notifications-dynamodb` | Deployment `notifications-dynamodb` |
| Criação da tabela | serviço `notifications-dynamodb-init` (roda e sai) | container `init-table` no pod do DynamoDB |

### Subindo

Não há passo extra: as funções fazem parte da stack local.

| Ambiente | Comando | O que acontece |
|---|---|---|
| Compose | `docker-compose up --build` | builda a imagem `fcg/notifications-lambda:local`; o `notifications-dynamodb-init` cria a tabela e sai com `Exited (0)` — é o esperado |
| k8s, automatizado | `make k8s-up` | builda e carrega `fcg/notifications-lambda:1.0` junto com as imagens das APIs e gera o ConfigMap do init da tabela |
| k8s, manual | [Passo a passo manual](#passo-a-passo-manual-o-que-o-make-k8s-up-automatiza), passos 2, 4 e 5 | build da imagem, ConfigMap do init e verificação da tabela |

O código vem do repositório do NotificationsAPI, que precisa estar clonado ao lado deste (ou em `NOTIFICATIONS_API_PATH`, no `.env`). Mudou o código lá? Basta rebuildar aqui:

```bash
docker-compose up -d --build notifications-user-registered notifications-payment-processed   # Compose
make k8s-build   # k8s: detecta a imagem nova e rola os dois Deployments
```

### Testando as notificações

O corpo é o **próprio evento de integração** — o mesmo JSON que o `users-api` e o `payments-api` publicam no SNS. O gateway o embrulha no envelope `{"Records":[{"body": ...}]}` que o handler espera, como o SQS faz. Se você já mandar o envelope (por exemplo, um dos `events/*.json` do repo do NotificationsAPI), ele passa intacto.

```bash
GATEWAY=http://localhost:8000
TOKEN=$(curl -s -X POST $GATEWAY/users/api/auth/login -H "Content-Type: application/json" \
  -d '{"email":"teste@fcg.com","password":"Senha123!"}' | jq -r .accessToken)

# 1. Cadastro -> grava a notificação de boas-vindas e "envia" o e-mail (log)
curl -s -X POST $GATEWAY/notifications/user-registered \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"UserId":"11111111-1111-1111-1111-111111111111","Name":"Ana","Email":"ana@exemplo.com","EventId":"22222222-2222-2222-2222-222222222222","OccurredAt":"2026-09-10T12:00:00Z"}'
# {"batchItemFailures":[]}

# 2. Pagamento aprovado (Status 1) do MESMO usuário -> confirmação de compra
curl -s -X POST $GATEWAY/notifications/payment-processed \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"UserId":"11111111-1111-1111-1111-111111111111","GameId":"33333333-3333-3333-3333-333333333333","Status":1,"EventId":"44444444-4444-4444-4444-444444444444","OccurredAt":"2026-09-10T12:00:00Z"}'
# {"batchItemFailures":[]}
```

A resposta é o `SQSBatchResponse` da função — o mesmo que o SQS recebe na AWS:

| Resposta | Significado |
|---|---|
| `{"batchItemFailures":[]}` | processado — **ou** descartado de propósito: evento duplicado ou JSON malformado (na AWS, reentregar não adiantaria). O motivo fica no log. |
| `{"batchItemFailures":[{"itemIdentifier":"..."}]}` | falhou; na AWS o SQS reentregaria. Caso típico: pagamento de um usuário cujo cadastro ainda não chegou (`RecipientNotReadyException`) — mande o cadastro antes. Se o log falar em tabela inexistente, ver [troubleshooting](#notificação-falha-com-resourcenotfoundexception-tabela-inexistente). |

A primeira chamada de cada função leva ~2 s (cold start, como na Lambda); as seguintes, décimos de segundo.

Para ver o resultado:

```bash
# Compose
docker-compose logs notifications-user-registered notifications-payment-processed
docker-compose run --rm --entrypoint aws \
  -e AWS_ACCESS_KEY_ID=local -e AWS_SECRET_ACCESS_KEY=local -e AWS_DEFAULT_REGION=us-east-1 \
  notifications-dynamodb-init \
  dynamodb scan --table-name fcg-notifications --endpoint-url http://notifications-dynamodb:8000

# k8s
kubectl logs -n fcg deploy/notifications-user-registered
kubectl exec -n fcg deploy/notifications-dynamodb -c init-table -- \
  aws dynamodb scan --table-name fcg-notifications --endpoint-url http://localhost:8000
```

> **O que não acontece localmente.** Não existe o encadeamento automático SNS → SQS → Lambda: o `users-api` e o `payments-api` continuam publicando no SNS **da AWS** (e, sem credenciais válidas, só logam um aviso). Cadastrar um usuário pelo `/users` não dispara a função local — as rotas `/notifications/...` são o gatilho aqui. O DynamoDB Local é em memória: o conteúdo some ao recriar o container ou o pod.

> **Schema da tabela.** `notifications-local/init-dynamodb.sh` espelha a tabela do `template.yaml` (chave `PK`, índice `GSI1-UserId`). Se o schema mudar lá, mude aqui. O Compose roda o script a cada `up`; no k8s, o `make k8s-deploy` rola o pod do DynamoDB quando o script muda.

## Serverless (NotificationsAPI)

O `NotificationsAPI` da Fase 2 (container ASP.NET Core rodando 24/7 no Kubernetes, só para consumir eventos do RabbitMQ) foi **migrado para uma função AWS Lambda**, atendendo ao requisito obrigatório de "Migração para Arquitetura Serverless" da Fase 3.

> **Testar sem AWS:** as mesmas funções rodam localmente no emulador da Lambda, atrás do Kong — ver [NotificationsAPI local (via Kong)](#notificationsapi-local-via-kong). Nada disso altera o que está provisionado na AWS.

- **Repositório próprio (código + IaC):** https://github.com/joao-malvetoni-alta-horizon/FIAPCloudGames-fase3-NotificationsAPI
- **Infraestrutura como código:** AWS SAM (`template.yaml` na raiz daquele repositório).
- **Arquitetura:** `UsersAPI`/`PaymentsAPI` publicam `UserRegisteredEvent`/`PaymentProcessedEvent` num tópico **SNS**, que entrega numa fila **SQS** (com DLQ), que aciona a **Lambda** correspondente — sem nenhum componente rodando continuamente.
- **Persistência:** DynamoDB (`fcg-notifications`), atendendo também o requisito obrigatório de NoSQL.
- **Observabilidade:** OpenTelemetry exportando para o New Relic (traces e, em configuração, métricas/logs), consistente com a escolha de Opção B (New Relic) do grupo.

Recursos provisionados na AWS (conta usada pelo grupo, região `us-east-1`):

| Recurso | Nome |
|---|---|
| Stack CloudFormation | `fcg-notifications-serverless` |
| Funções Lambda | `fcg-notifications-user-registered`, `fcg-notifications-payment-processed` |
| Tópicos SNS | `fcg-user-events`, `fcg-payment-events` |
| Filas SQS (+ DLQ) | `fcg-notifications-user-registered`, `fcg-notifications-payment-processed` |
| Tabela DynamoDB | `fcg-notifications` |

`UsersAPI` e `PaymentsAPI` publicam `UserRegisteredEvent`/`PaymentProcessedEvent` diretamente nos tópicos SNS acima (ver `Sns__TopicArn` na tabela abaixo) — o fluxo é acionado por qualquer cadastro de usuário ou pagamento processado real do sistema, sem precisar de publicação manual via CLI/console. O RabbitMQ continua em uso só para o fluxo `catalog-api` -> `payments-api` (`OrderPlacedEvent`), que não muda com essa migração.

## Variáveis de ambiente por serviço

| Variável | users | catalog | payments | Origem |
|---|:---:|:---:|:---:|---|
| `ConnectionStrings__DefaultConnection` | Sim | Sim | Sim | Secret |
| `ConnectionStrings__Redis` | — | Sim | — | Secret (`Catalog__RedisConnection`) |
| `RabbitMq__Host` | — | Sim | Sim | ConfigMap |
| `RabbitMq__Port` | — | Sim | Sim | ConfigMap |
| `RabbitMq__Username` | — | Sim | Sim | ConfigMap |
| `RabbitMq__VirtualHost` | — | Sim | Sim | ConfigMap |
| `RabbitMq__Password` | — | Sim | Sim | Secret |
| `Sns__TopicArn` | Sim | — | Sim | ConfigMap |
| `AWS_REGION` | Sim | — | Sim | ConfigMap |
| `AWS_ACCESS_KEY_ID` | Sim | — | Sim | Secret |
| `AWS_SECRET_ACCESS_KEY` | Sim | — | Sim | Secret |
| `JwtSettings__SecretKey` | Sim | Sim | — | Secret |
| `ASPNETCORE_ENVIRONMENT` | Sim | Sim | Sim | ConfigMap |
| `NEW_RELIC_LICENSE_KEY` | Sim | Sim | Sim | Secret (`k8s/04-new-relic-secret.yaml`) |
| `CORECLR_ENABLE_PROFILING` | Sim | Sim | Sim | fixa no manifesto/Compose |
| `CORECLR_PROFILER` | Sim | Sim | Sim | fixa no manifesto/Compose |
| `CORECLR_NEWRELIC_HOME` | Sim | Sim | Sim | fixa no manifesto/Compose |
| `CORECLR_PROFILER_PATH` | Sim | Sim | Sim | fixa no manifesto/Compose |

> **As quatro `CORECLR_*` não são opcionais.** O pacote NuGet `NewRelic.Agent` coloca o
> agente em `/app/newrelic`, mas o .NET só instrumenta a aplicação quando o profiler do CLR
> é habilitado por estas variáveis. Sem elas o agente fica **inerte e silencioso**: nenhum
> erro no log, e zero métricas, logs ou traces chegando no New Relic. Já aconteceu neste
> projeto — o sintoma foi "a license key está certa, o agente está instalado e mesmo assim
> não aparece nada no New Relic".

O gateway consome duas variáveis próprias:

| Variável | Origem (k8s) | Origem (Compose) | Para que |
|---|---|---|---|
| `JWT_SECRET_KEY` | Secret `fcg-secrets` (`JwtSettings__SecretKey`) | `.env` | chave HMAC para validar a assinatura do token |
| `JWT_ISSUER` | ConfigMap `fcg-config` | `.env` (default `FCG`) | claim `iss` esperada nos tokens; o users-api lê a mesma variável em `JwtSettings__Issuer` |

As demais variáveis do Kong (`KONG_*`) são fixas no manifesto/Compose e não dependem de ConfigMap nem Secret. As que valem conhecer: `KONG_ADMIN_LISTEN` (Admin API no loopback do pod), `KONG_TRUSTED_IPS`/`KONG_REAL_IP_HEADER`/`KONG_REAL_IP_RECURSIVE` (IP real do cliente atrás do Ingress, para o rate-limit por IP) e `KONG_HEADERS=latency_tokens` (mantém os headers de latência, tira o `Server: kong/<versao>`).

> **Nota:** o `catalog-api` lê a seção `RabbitMq:` como o `payments-api` — as mesmas keys. (Ele já usou uma URI `amqp://` em `ConnectionStrings__RabbitMqConnection`; se voltar a injetar só aquela, o app cai no `guest`/`pass` do `appsettings.json` e o broker recusa com `ACCESS_REFUSED`.) O `catalog-api` é também o único que usa Redis — ver [Cache (Redis)](#cache-redis). `users` e `catalog` compartilham a mesma `JwtSettings__SecretKey`. `payments` tem banco próprio (`paymentsdb`), não usa JWT, e publica `PaymentProcessedEvent` em dois transportes: RabbitMQ (de volta pro `catalog-api`, libera o jogo na biblioteca) e SNS (para a Lambda do NotificationsAPI). As credenciais AWS são só para o SNS; sem elas essa publicação falha silenciosamente (log de warning) e o restante do fluxo (RabbitMQ/HTTP) continua normal.

As funções **locais** do NotificationsAPI não usam ConfigMap nem Secret: os valores são fixos no `docker-compose.yml` e em `k8s/23-notifications.yaml`, e **nunca** apontam para credenciais reais.

| Variável | Valor local | Para que |
|---|---|---|
| `DynamoDb__ServiceUrl` | `http://notifications-dynamodb:8000` | aponta o SDK para o DynamoDB Local; na AWS ela não existe e o SDK usa o DynamoDB real |
| `DynamoDb__TableName` | `fcg-notifications` | mesma tabela do `template.yaml` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | `local` | o SDK exige credencial mesmo com o DynamoDB Local, que roda com `-sharedDb` e as ignora |
| `AWS_REGION` | `us-east-1` | idem |
| `NEW_RELIC_LICENSE_KEY` | `local-dev-placeholder` | o `Telemetry.cs` aborta a função sem ela; com o placeholder os traces são recusados, sem afetar a execução |

No `.env`, `NOTIFICATIONS_API_PATH` diz onde está o repo do NotificationsAPI (default `../FIAPCloudGames-fase3-NotificationsAPI`), como `USERS_API_PATH` e os demais.

> **Secret** é apenas base64 (não é cofre). Não comite valores reais.

## Observabilidade (New Relic)

O grupo optou pela **Opção B** do enunciado (plataforma de APM gerenciada): **New Relic**, cobrindo os três pilares (métricas, logs e traces) em `UsersAPI`, `CatalogAPI`, `PaymentsAPI` e na função serverless. Detalhes em [`docs/observability.md`](docs/observability.md). O salto pelo RabbitMQ é o ponto delicado dos traces — a instrumentação automática do agente não cobre o cliente AMQP que usamos, e a propagação é feita no código dos serviços: ver [Propagação de trace pelo RabbitMQ](#propagação-de-trace-pelo-rabbitmq). A license key é injetada via Kubernetes Secret (`k8s/04-new-relic-secret.yaml`) e, localmente, pela variável `NEW_RELIC_LICENSE_KEY` no `.env` (ver `.env.example`); nunca é commitada em texto puro no código-fonte, conforme exigido pelo enunciado para a Opção B.

Como o manifesto `k8s/04-new-relic-secret.yaml` é versionado, ele guarda apenas um
**placeholder**. Quem põe o valor real no cluster é o `scripts/k8s/secrets.sh`, que lê o
`.env` (a mesma fonte do Compose) e sobrepõe os segredos **depois** do `kubectl apply` —
a license key do New Relic e as credenciais AWS de `fcg-secrets`. O `deploy.sh` já o chama,
então `make k8s-up` faz isso sozinho; para reaplicar depois de trocar um valor no `.env`,
use `make k8s-secrets`.

Como Secret lido por variável de ambiente só é resolvido na criação do container, o script
grava o **hash** dos valores numa annotation do pod template (mesma técnica do ConfigMap do
Kong): os Deployments rolam quando o segredo muda, e só então. Na annotation vai o hash,
nunca o valor.

### Propagação de trace pelo RabbitMQ

**O sintoma.** Os traces não atravessavam o broker. No New Relic, cada serviço aparecia
como um trace isolado: o `catalog-api` terminava a transação ao publicar o
`OrderPlacedEvent` e o resto da saga simplesmente não existia do outro lado. Pior, o
`payments-api` não aparecia em APM **de jeito nenhum** — o único endpoint HTTP dele é
`/health`, e todo o trabalho real acontece no consumo da fila, que não estava
instrumentado.

**A causa.** Incompatibilidade de versão entre o agente e o cliente AMQP. O wrapper de
RabbitMQ do agente New Relic .NET 10.54.0 casa apenas até a **6.8.1**, e o projeto usa o
**RabbitMQ.Client 7.2.1**. Dá para ler direto de dentro do pod:

```bash
kubectl exec -n fcg deploy/catalog-api -- \
  grep -o 'maxVersion="[^"]*"' /app/newrelic/extensions/NewRelic.Providers.Wrapper.RabbitMq.Instrumentation.xml
# maxVersion="6.8.1"
```

O profiler diz a mesma coisa, nas próprias palavras dele
(`/app/newrelic/logs/NewRelic.Profiler.*.log`):

```
Unable to find RabbitMQ.Client.Framing.Impl.Model for rejit. HR:-2146234064
Unable to find RabbitMQ.Client.Events.EventingBasicConsumer for rejit. HR:-2146234064
```

As classes que o wrapper procura (`RabbitMQ.Client.Framing.Impl.Model`,
`EventingBasicConsumer`) deixaram de existir na v7. Sem rejit não há span de
publish/consume e, principalmente, **não há propagação de contexto**: uma mensagem real
capturada da `catalog.exchange` trazia só
`{"delivery_mode":2,"content_type":"application/json"}` — nenhum header. Repare que o
agente não reclama disso como erro: ele registra em `[Info ]` e segue silencioso, o que
faz o sintoma parecer "o New Relic não mostra a saga" em vez de "a instrumentação não
casou".

**A solução — propagação manual.** A correção é de código, nos serviços; este repo não
muda nada de configuração por causa dela.

- O pacote `FiapCloudGames.RabbitMq` **1.1.0** passou a expor os headers da mensagem na
  publicação e no consumo (antes eles nem chegavam à aplicação).
- O `catalog-api` injeta o contexto ao publicar o `OrderPlacedEvent`, com
  `InsertDistributedTraceHeaders` e `TransportType.Queue`.
- O `payments-api` aceita o contexto ao consumir, com `AcceptDistributedTraceHeaders`
  (também `TransportType.Queue`), marca o método de consumo como `[Transaction]` — sem
  isso não existe transação à qual anexar o contexto — e injeta de novo ao publicar o
  `PaymentProcessedEvent`, fechando o caminho de volta para o `catalog-api`.

**Onde o trace começa.** No `catalog-api`. O **Kong não roda agente .NET** e portanto não
é um span: não adianta procurar o gateway no waterfall do New Relic, ele não está lá e não
vai estar. O primeiro span é a transação HTTP do `catalog-api`.

### Alternativas avaliadas e descartadas

| Alternativa | Por que não |
|---|---|
| Baixar o `RabbitMQ.Client` para 6.8.1, entrando na faixa que o agente instrumenta | O `FiapCloudGames.RabbitMq` é compilado contra APIs que só existem na v7 — `IChannel`, `CreateChannelAsync`, `BasicPublishAsync`, `AsyncEventingBasicConsumer.ReceivedAsync`, `BasicProperties` como classe. Com a 6.8.1 o build até passa em alguns pontos, mas o runtime quebra com `MissingMethodException`. |
| Migrar os três serviços .NET para OpenTelemetry | É a solução mais limpa a longo prazo e alinharia com a Lambda do NotificationsAPI, que já usa OTel + OTLP. Mas é trocar a stack de telemetria inteira dos três serviços, grande demais para o prazo desta entrega. **Fica registrada como dívida técnica.** |
| Esperar o agente suportar o `RabbitMQ.Client` 7.x | Fora do nosso controle e sem data anunciada. |

### Validando a propagação (`scripts/validate-tracing.sh`)

O script derruba a pergunta "o trace atravessa o broker?" para um exit code, sem depender
de olhar a UI do New Relic:

```bash
./scripts/validate-tracing.sh
```

O que ele faz:

1. Detecta o ambiente — gateway em `:8200` (port-forward do k8s) ou `:8000` (Compose) — e
   fala com o broker por `kubectl exec` ou `docker compose exec`, conforme o caso.
2. Cria duas **filas espias** ligadas às mesmas exchanges/routing keys da saga
   (`catalog.exchange`/`order.placed` e `payments.exchange`/`payment.status`). São cópias:
   os consumidores reais continuam recebendo tudo.
3. Autentica, escolhe um jogo que ainda não está na biblioteca (cria um, se precisar) e
   dispara uma compra de verdade.
4. Lê uma mensagem de cada fila e exige o header `traceparent` nas duas, **com o mesmo
   trace-id** — é essa igualdade que separa "cada serviço abriu um trace próprio" de "o
   contexto atravessou o broker".
5. Apaga as filas espias no fim, inclusive em erro ou `Ctrl-C` (`trap`). As filas têm nome
   fixo e são removidas também no começo da execução, então rodar duas vezes seguidas não
   deixa lixo no broker.

Duas armadilhas que o script trata, as duas já custaram tempo aqui:

- **Token expirado.** O JWT dura ~1h; com token vencido o Kong devolve `401` e a requisição
  nem chega ao `catalog-api` — não há mensagem publicada e qualquer conclusão sobre headers
  seria chute. Por isso o script tira um token novo a cada execução e **exige `202` na
  compra** antes de olhar para qualquer header.
- **Porta 8100.** É o listener de *status* do Kong no Compose e responde `404` em rota de
  aplicação. O script nunca a usa como gateway, e você também não deveria.

Variáveis opcionais: `FCG_EMAIL`, `FCG_PASSWORD`, `FCG_NAMESPACE` (default `fcg`),
`RABBITMQ_USER`/`RABBITMQ_PASS` (default `fcg`/`fcg123`) e `TRACE_TIMEOUT` (segundos de
espera por cada mensagem, default `60`).

> **Enquanto as correções do `catalog-api` e do `payments-api` não estiverem mergeadas *e*
> deployadas, este script falha** — e é assim que ele deve se comportar. A saída aponta o
> que falta:
>
> ```
> SEM traceparent  catalog.exchange / order.placed  (publicado pelo catalog-api)
> headers recebidos: {}
> ```
>
> Sem a correção deployada, o Bloco 5.4 do `ROTEIRO-VIDEO.md` não tem trace distribuído
> pela mensageria para mostrar. A alternativa honesta é exibir o trace de uma requisição
> HTTP com os spans de Postgres e Redis — que existe e é legítimo — e declarar a limitação
> do salto pelo broker com a causa técnica na mão.
