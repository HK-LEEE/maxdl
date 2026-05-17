-- 자동생성: maxplatform.service_requests Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__service_requests')) }}
from {{ ref('stg_maxplatform__service_requests') }}
