-- 자동생성: maxapex.log_counts Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__log_counts')) }}
from {{ ref('stg_maxapex__log_counts') }}
