-- 자동생성: maxplatform.client_status_history Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__client_status_history')) }}
from {{ ref('stg_maxplatform__client_status_history') }}
