-- 자동생성: maxapex.maxapex_pm_data_sources Silver (replica: 정제 passthrough, 전체교체)
{{ config(materialized='table') }}
select {{ dbt_utils.star(from=ref('stg_maxapex__maxapex_pm_data_sources')) }}
from {{ ref('stg_maxapex__maxapex_pm_data_sources') }}
