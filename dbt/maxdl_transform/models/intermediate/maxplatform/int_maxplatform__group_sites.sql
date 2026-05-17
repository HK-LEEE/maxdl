-- 자동생성: maxplatform.group_sites Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxplatform__group_sites')) }}
from {{ ref('stg_maxplatform__group_sites') }}
