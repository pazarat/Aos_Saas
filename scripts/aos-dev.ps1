param(
  [Parameter(Mandatory=$true)]
  [ValidateSet(
    "status",
    "snapshot",
    "build-agent",
    "build-app",
    "up",
    "restart-app",
    "clean-exited-runtimes",
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
  Write-Host "--- Agent image ---"
  $currentAgentImageId = (docker image inspect aos-agent-server:dev --format "{{.Id}}" 2>$null)
  if ($LASTEXITCODE -eq 0 -and $currentAgentImageId) {
    $shortCurrentAgentImageId = $currentAgentImageId.Replace("sha256:", "").Substring(0, 12)
    Write-Host "aos-agent-server:dev -> $shortCurrentAgentImageId"
  } else {
    $shortCurrentAgentImageId = ""
    Write-Host "aos-agent-server:dev -> NOT_FOUND"
  }

  Write-Host ""
  Write-Host "--- Agent runtimes ---"
  $runtimes = docker ps -a --filter "name=oh-agent-server" --format "{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"
  if (-not $runtimes) {
    Write-Host "No oh-agent-server runtimes found."
  } else {
    $runtimes | ForEach-Object {
      $p = $_ -split "\|", 4
      $name = $p[0]
      $image = $p[1]
      $status = $p[2]
      $ports = $p[3]

      $runtimeImageId = (docker inspect $name --format "{{.Image}}" 2>$null)
      $runtimeShortImageId = if ($runtimeImageId) { $runtimeImageId.Replace("sha256:", "").Substring(0, 12) } else { "unknown" }

      $match = if ($shortCurrentAgentImageId -and ($runtimeShortImageId -eq $shortCurrentAgentImageId)) {
        "CURRENT_IMAGE"
      } else {
        "OLD_RUNTIME_IMAGE"
      }

      [PSCustomObject]@{
        Name = $name
        Image = $image
        ImageId = $runtimeShortImageId
        Match = $match
        Status = $status
        Ports = $ports
      }
    } | Format-Table -AutoSize
  }

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

  "clean-exited-runtimes" {
    Invoke-AosSnapshot

    Write-Host ""
    Write-Host "--- Cleaning stopped agent runtimes only ---"

    $containers = @()
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=exited"
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=created"
    $containers += docker ps -aq --filter "name=oh-agent-server" --filter "status=dead"

    $containers = $containers | Where-Object { $_ } | Sort-Object -Unique

    if (-not $containers) {
      Write-Host "No stopped oh-agent-server runtimes to remove."
    } else {
      $containers | ForEach-Object {
        Write-Host "Removing stopped runtime container: $_"
        docker rm $_
      }
    }

    Invoke-AosSnapshot
  }

  "prune-dangling-images" {
    docker image prune -f --filter "dangling=true"
  }
}
