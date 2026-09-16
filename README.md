# ed-gender — stops and places from app check-in pings

Pipeline for turning opportunistic app check-in pings (Edinburgh, 26 Aug – 13 Oct
2024, ~111M pings, ~1M users) into **stops** (stay-points per user) and
**places** (locations shared across users), as input to infer gender from smart geographic data.

The data are not continuous GPS traces: a ping is an isolated check-in, sampling
is highly irregular between users, and a "stop" therefore means "pings clustered
in space and time", nothing more. Durations are lower bounds.

