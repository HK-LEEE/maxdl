-- 자동생성: maxplatform.factories Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__factories')) }}
from {{ ref('stg_maxplatform__factories') }}
