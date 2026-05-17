-- 자동생성: maxtdoracle.production_log Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxtdoracle__production_log')) }}
from {{ ref('stg_maxtdoracle__production_log') }}
