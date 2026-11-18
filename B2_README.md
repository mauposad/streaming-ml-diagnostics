# B2 — Green but Broken: reproduction, results, and explanation

## Scope and environment

B2 investigates an HTTP scorer that reports healthy while prediction requests fail. The work covered a working baseline, controlled fault injection, diagnosis, configuration repair, readiness hardening, and repeated functional checks.

Experiment date: November 18, 2026. Local Python: 3.12.16. Scorer container Python: 3.11.18. Docker Engine: 29.9.3. Docker Compose: 5.7.0. Commands below run from the repository root.

## Diagnosis and hypothesis

The supplied docker/compose.b2-broken.yaml overrides MODEL_PATH with /app/models/artifacts/model-b2-missing.pkl. The actual artifact is /app/models/artifacts/model.pkl.

Before the change:
- Container logs reported the missing artifact and continued HTTP startup.
- GET /health returned HTTP 200 with model_loaded=false.
- Docker marked the scorer healthy because its probe only checked the successful HTTP response.
- The same valid POST /score that worked in the baseline returned HTTP 503.

The artifact existed and had already served a successful prediction. Therefore, the investigation pointed to a deployment-path mismatch.

**Hypothesis:** the wrong model path prevents model loading, while the HTTP-only health probe produces a false healthy status. Correcting the path and recreating the process should restore scoring.

**Falsifying observation:** if the corrected effective path and a recreated scorer still fail to restore the same valid scoring request, the path mismatch is not a sufficient explanation and additional diagnosis is needed.

## Repair and implementation

Recreating the scorer with the base Compose configuration restored the correct model path and HTTP 200 scoring. The existing artifact was used; no further training was needed for the repair. Model loading happens at process startup, so restarting an unchanged broken deployment would repeat the configuration fault.

Two implementation changes were made:
1. scoring/score_service.py: add GET /ready. It returns HTTP 200 only when both the model and scaler are loaded; otherwise HTTP 503. The response includes both dependency flags.
2. docker/compose.yaml: change only the scorer healthcheck URL from /health to /ready. Keep interval=10s, timeout=5s, retries=5, and start_period=10s.

The supplied broken override remains unchanged for repeatable fault injection.

## Observed results

| Condition | GET /health | GET /ready | POST /score | Docker status |
|---|---|---|---|---|
| Original baseline | 200, model loaded | Not implemented | 200 | healthy |
| Original code + broken path | 200, model not loaded | Not implemented | 503 | healthy (false green) |
| Original code after path repair | 200, model loaded | Not implemented | 200 | healthy |
| Hardened code + correct path | 200 | 200 | 200 | healthy |
| Hardened code + same broken path | 200 | 503 | 503 | unhealthy |
| Hardened code after final recovery | 200 | 200 | 200 | See final recovery status evidence |

The fixed request returned score=6.514147292084253e-09 and spike=false in the baseline and after recovery. A low score is a valid prediction, not a request failure. The sampled hardened-fault failing streak was eight; this is a failure count, not an exact detection-latency measurement.

## Reproduction

First follow the root README to install dependencies, start the stack, replay the sample, generate features, and run the provided training script. The original baseline used 782 replayed messages and 400 generated feature rows. The scorer needs models/artifacts/model.pkl, which is generated locally and mounted into the container. On a fresh setup, the improved scorer is expected to be not ready until training creates the artifact and the scorer is restarted.

The pre-change reference commit is recorded in evidence/b2/base-commit.txt. To reproduce the original false-green behavior, inspect that commit in a separate checkout and apply the supplied fault override after completing its baseline setup. The instructions below exercise the improved version.

Build and start the improved scorer using the correct configuration:

~~~bash
docker compose -f docker/compose.yaml up -d --build --force-recreate scorer
~~~

Check liveness, readiness, and actual scoring:

~~~bash
curl -sS -i http://localhost:8000/health
curl -sS -i http://localhost:8000/ready
curl -sS -i -X POST http://localhost:8000/score -H 'Content-Type: application/json' -d '{"midprice_returns":0.001,"spread_normalized":0.0002,"order_book_imbalance":0.1,"trade_intensity":12}'
docker compose -f docker/compose.yaml ps
~~~

All three endpoints should return HTTP 200. Allow Docker's first probe to run before expecting healthy.

Inject the same controlled model-path fault:

~~~bash
docker compose -f docker/compose.yaml -f docker/compose.b2-broken.yaml up -d --force-recreate scorer
~~~

Repeat the same endpoint checks. Expected: /health 200, /ready 503, /score 503. Allow the startup grace period and consecutive-failure threshold to elapse before expecting unhealthy.

Collect configuration and diagnostic evidence as needed:

~~~bash
docker compose -f docker/compose.yaml -f docker/compose.b2-broken.yaml config
docker compose -f docker/compose.yaml logs --no-color --tail 100 scorer
docker compose -f docker/compose.yaml exec -T scorer printenv MODEL_PATH
docker compose -f docker/compose.yaml exec -T scorer ls -l /app/models/artifacts
docker inspect scorer --format '{{json .Config.Healthcheck}}'
docker inspect scorer --format '{{json .State.Health}}'
~~~

Restore the base configuration and repeat the endpoint and container checks:

~~~bash
docker compose -f docker/compose.yaml up -d --force-recreate scorer
~~~

## Evidence map

All evidence is under evidence/b2/.

| Directory | Purpose |
|---|---|
| baseline | Original healthy container and successful real scoring request |
| broken-original | False-green symptom, logs, effective configuration, model path, and actual files |
| repaired-original | Correct path, successful model loading, and restored scoring |
| hardened-normal | New readiness endpoint, successful scoring, and actual probe configuration |
| hardened-broken | Same fault detected by readiness and Docker; raw health-probe history |
| hardened-recovered | Final recovered endpoint responses, model path, and refreshed container status |

## Tradeoffs, limitations, and recommendation

The readiness check is inexpensive and detects this missing-artifact failure, but it only checks whether dependencies are loaded. It does not execute canary inference, prove feature compatibility for every input, or assess prediction accuracy. Actual POST /score requests separately validate representative functional inference.

Synthetic inference could detect additional runtime failures, but would add CPU and latency cost. Probe timeouts and retry thresholds also trade detection speed against transient failures. Keep the lightweight readiness check and repeat functional smoke tests during deployment. If readiness is later used to gate traffic, that routing behavior must be configured explicitly: this Compose setup does not automatically block requests or restart a container merely because it is unhealthy.

## AI supervision

| AI recommendation | Decision and reasoning | Verification |
|---|---|---|
| Restore the correct MODEL_PATH and recreate the scorer | Accepted: the trained artifact already existed; the effective deployment path was wrong | Inspected environment, file listing, and logs; the same request recovered from 503 to 200 |
| Add a separate readiness endpoint and use it for Docker health | Accepted with scope limited to model/scaler loading; retained a real scoring request as a functional test | Tested normal operation and the identical injected fault; false green changed to unhealthy |

## Oral explanation — English

I was responsible for B2, where the scorer looked healthy but could not provide predictions. I established a working baseline and reproduced the failure using the supplied Compose override. Logs, configuration, and container files showed an incorrect model path. I restored the correct configuration, then added a readiness endpoint checking the model and scaler and updated Docker to use it. Repeating the same failure produced readiness 503 and Docker unhealthy, while restoring the configuration recovered scoring. This improves detection of missing model dependencies; it does not prove model accuracy or automatically block traffic.

## 口头解释 — 中文

我负责 B2：评分服务看起来健康，却无法提供预测。我先验证正常基线，再用老师提供的 Compose 覆盖配置复现故障。日志、配置和容器文件共同表明模型路径错误。我恢复正确配置，然后新增检查模型和标准化器是否加载的 readiness 接口，并让 Docker 使用它。再次注入相同故障后，readiness 返回 503，Docker 显示 unhealthy；恢复配置后预测成功。这个改动改善了模型依赖缺失的检测，但不能证明模型准确，也不会自动阻断流量。

## Q&A reminders / 答辩要点

| Question | Answer |
|---|---|
| Why not retrain? / 为什么不重新训练？ | The artifact existed and worked after the path correction. 模型已存在，修正路径后就恢复预测。 |
| Why separate health and readiness? / 为什么分开？ | HTTP responsiveness and loaded model dependencies are different conditions. HTTP 能响应与模型依赖已加载是不同状态。 |
| Would a restart fix the broken configuration? / 只重启够吗？ | An unchanged wrong path fails again; apply the corrected configuration and recreate. 错误路径不变就会重复失败。 |
| Does ready prove correct predictions? / ready 能证明预测正确吗？ | No; it checks loaded dependencies. Functional inference and quality need separate checks. 它只检查依赖加载，功能与质量需要分别验证。 |
| Does unhealthy automatically stop traffic? / 会自动阻断请求吗？ | No; this setup exposes the failure without automatic routing or restart. 当前配置只暴露故障，不自动切流或重启。 |

