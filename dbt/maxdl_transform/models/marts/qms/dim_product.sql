-- [샘플] MAX-APEX 제품 디멘전 (도메인 확정 전 예시)
{{ config(materialized='table') }}
select id as product_id, product_code, product_name, product_grade,
       quality_grade, product_category, plant_code, factory_code,
       is_active, createdat as created_at
from {{ ref('int_maxapex__maxapex_batch_product') }}
