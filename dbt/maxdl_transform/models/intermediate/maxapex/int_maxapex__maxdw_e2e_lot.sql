-- 자동생성: maxapex.maxdw_e2e_lot Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__maxdw_e2e_lot')) }}
from {{ ref('stg_maxapex__maxdw_e2e_lot') }}
