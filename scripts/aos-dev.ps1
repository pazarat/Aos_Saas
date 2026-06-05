param(
  [Parameter(Mandatory=$true)]
  [ValidateSet(
    "status",
    "snapshot",
    "build-agent",
    "build-app",
    "up",
    "restart-app",
    "prune-dangling-images"
  )]
  [string]$Action
)

$ErrorActionPreference = "Stop"

$ComposeFile = "docker-compose.aos-dev.yml"
$ProjectName = "aos_saas"

function Invoke-AosCompose {
  docker compose -p $ProjectName -f $ComposeFile @args
}

function Invoke-AosSnapshot {
  Write-Host ""
  Write-Host "=== AOS DEV SNAPSHOT ==="

  Write-Host ""
  Write-Host "--- Volumes ---"
  docker volume ls | Select-String "aos_saas"

  Write-Host ""
  Write-Host "--- Compose services ---"
  Invoke-AosCompose ps

  Write-Host ""
  Write-Host "--- Conversations count ---"
  docker exec aos-openhands-postgres psql -U openhands -d openhands -c "SELECT COUNT(*) AS conversations FROM conversation_metadata;" 2>$null

  Write-Host ""
  Write-Host "--- Latest conversations ---"
  docker exec aos-openhands-postgres psql -U openhands -d openhands -c "SELECT conversation_id,llm_model,sandbox_id,created_at FROM conversation_metadata ORDER BY created_at DESC LIMIT 10;" 2>$null

  Write-Host ""
  Write-Host "--- Agent runtimes ---"
  docker ps -a --filter "name=oh-agent-server" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

  Write-Host ""
  Write-Host "--- Main containers ---"
  docker ps -a --filter "name=aos-openhands" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

  Write-Host ""
  Write-Host "=== END SNAPSHOT ==="
}

switch ($Action) {
  "status" {
    Invoke-AosSnapshot
  }

  "snapshot" {
    Invoke-AosSnapshot
  }

  "build-agent" {
    Invoke-AosSnapshot
    Invoke-AosCompose --profile build build agent-server-image
    docker image prune -f --filter "dangling=true"
    Invoke-AosSnapshot
  }

  "build-app" {
    Invoke-AosSnapshot
    Invoke-AosCompose build openhands
    docker image prune -f --filter "dangling=true"
    Invoke-AosSnapshot
  }

  "up" {
    Invoke-AosCompose up -d
    Invoke-AosSnapshot
  }

  "restart-app" {
    Invoke-AosSnapshot
    Invoke-AosCompose up -d --no-deps --force-recreate openhands
    Invoke-AosSnapshot
  }

  "prune-dangling-images" {
    docker image prune -f --filter "dangling=true"
  }
}
