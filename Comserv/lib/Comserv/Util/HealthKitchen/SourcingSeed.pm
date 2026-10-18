package Comserv::Util::HealthKitchen::SourcingSeed;
use strict;
use warnings;

# Reference rows for hk_sourcing_factor. Auto-seeded (insert-if-missing by
# food_category+attribute+attr_value) by Comserv::Util::HealthKitchen::ensure_sourcing_seed.
# Existing rows are never overwritten, so staff edits in the DB are preserved.
# nutrient_adj_json: percent change vs unspecified-source base values (estimates).

our @ROWS = @{ [
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'grass_fed',
    'attribute' => 'animal_raising',
    'citation' => 'Daley CA, Abbott A, Doyle PS, Nader GA, Larson S. A review of fatty acid profiles and antioxidant content in grass-fed and grain-fed beef. Nutr J. 2010;9:10.',
    'ethics_score' => 4,
    'food_category' => 'beef',
    'heavy_metal_risk' => undef,
    'hormone_risk' => 'low',
    'notes' => 'Leaner; higher omega-3, CLA and vitamin E precursors; better n-6:n-3 ratio.',
    'nutrient_adj_json' => '{"fat_g":-15,"calories":-8}',
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'med',
    'attr_value' => 'feedlot',
    'attribute' => 'animal_raising',
    'citation' => 'US FDA. Steroid Hormone Implants Used for Growth in Food-Producing Animals (2022); US FDA 2022 Summary Report on Antimicrobials Sold or Distributed for Use in Food-Producing Animals.',
    'ethics_score' => 1,
    'food_category' => 'beef',
    'heavy_metal_risk' => undef,
    'hormone_risk' => 'high',
    'notes' => 'Grain finishing raises marbling; growth-promoting hormone implants are permitted in US/Canada conventional beef.',
    'nutrient_adj_json' => '{"fat_g":10,"calories":5}',
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'organic_certified',
    'attribute' => 'production',
    'citation' => 'USDA National Organic Program, 7 CFR 205.237-205.239 (livestock feed, health care and living conditions); Canada Organic Regime CAN/CGSB-32.310.',
    'ethics_score' => 3,
    'food_category' => 'beef',
    'heavy_metal_risk' => undef,
    'hormone_risk' => 'low',
    'notes' => 'Organic standards prohibit routine antibiotics and growth hormones; require pasture access.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'low'
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'organic_certified',
    'attribute' => 'production',
    'citation' => 'Benbrook CM, Butler G, Latif MA, Leifert C, Davis DR. Organic production enhances milk nutritional quality by shifting fatty acid composition. PLoS ONE. 2013;8(12):e82429.',
    'ethics_score' => 3,
    'food_category' => 'dairy',
    'heavy_metal_risk' => undef,
    'hormone_risk' => 'low',
    'notes' => 'Organic milk ~60% more omega-3 (ALA) than conventional.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'low'
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'grass_fed',
    'attribute' => 'animal_raising',
    'citation' => 'Benbrook CM, Davis DR, Heins BJ, et al. Enhancing the fatty acid profile of milk through forage-based rations. Food Sci Nutr. 2018;6(3):681-700.',
    'ethics_score' => 4,
    'food_category' => 'dairy',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Grass-fed milk has the best n-6:n-3 ratio (~1:1) and higher CLA.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'pasture',
    'attribute' => 'animal_raising',
    'citation' => 'Karsten HD, Patterson PH, Stout R, Crews G. Vitamins A, E and fatty acid composition of the eggs of caged hens and pastured hens. Renew Agric Food Syst. 2010;25(1):45-54.',
    'ethics_score' => 4,
    'food_category' => 'eggs',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Pastured hens: ~2x vitamin E and higher omega-3 in yolks.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'med',
    'attr_value' => 'caged',
    'attribute' => 'animal_raising',
    'citation' => 'EFSA AHAW Panel. Welfare of laying hens on farm. EFSA Journal. 2023;21(2):7789.',
    'ethics_score' => 1,
    'food_category' => 'eggs',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Conventional cages severely restrict behaviour; welfare risk ranked highest.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'free_range',
    'attribute' => 'animal_raising',
    'citation' => 'EFSA AHAW Panel. Welfare of laying hens on farm. EFSA Journal. 2023;21(2):7789.',
    'ethics_score' => 3,
    'food_category' => 'eggs',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Outdoor access; welfare better than caged/barn systems.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'organic_certified',
    'attribute' => 'production',
    'citation' => 'Srednicka-Tober D, Baranski M, Seal C, et al. Composition differences between organic and conventional meat: a systematic literature review and meta-analysis. Br J Nutr. 2016;115(6):994-1011.',
    'ethics_score' => 3,
    'food_category' => 'chicken',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Organic meat ~50% more omega-3; no routine antibiotics.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'low'
  },
  {
    'antibiotic_risk' => 'med',
    'attr_value' => 'conventional',
    'attribute' => 'production',
    'citation' => 'US FDA 2022 Summary Report on Antimicrobials Sold or Distributed for Use in Food-Producing Animals; 21 CFR 556 (no hormones approved for poultry).',
    'ethics_score' => 2,
    'food_category' => 'chicken',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Medically important antimicrobials still sold for poultry use; hormones are NOT permitted in poultry (US/Canada).',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'med',
    'attr_value' => 'farmed',
    'attribute' => 'catch_method',
    'citation' => 'Hites RA, Foran JA, Carpenter DO, et al. Global assessment of organic contaminants in farmed salmon. Science. 2004;303(5655):226-229; USDA FoodData Central #175168 (farmed) vs #173686 (wild).',
    'ethics_score' => 2,
    'food_category' => 'salmon',
    'heavy_metal_risk' => 'med',
    'hormone_risk' => undef,
    'notes' => 'Farmed Atlantic ~13 g fat/100 g vs ~6 g wild; higher PCB/dioxin levels reported.',
    'nutrient_adj_json' => '{"fat_g":30,"calories":15}',
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'wild',
    'attribute' => 'catch_method',
    'citation' => 'USDA FoodData Central #173686 (Atlantic salmon, wild, raw); Hites RA et al. Science. 2004;303:226-229.',
    'ethics_score' => 4,
    'food_category' => 'salmon',
    'heavy_metal_risk' => 'low',
    'hormone_risk' => undef,
    'notes' => 'Leaner; lower persistent organic contaminants. Prefer MSC-certified stocks.',
    'nutrient_adj_json' => '{"fat_g":-30,"calories":-15}',
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => 'low',
    'attr_value' => 'wild',
    'attribute' => 'catch_method',
    'citation' => 'US FDA/EPA. Advice about Eating Fish (2021 update), mercury levels in commercial fish.',
    'ethics_score' => 3,
    'food_category' => 'fish_other',
    'heavy_metal_risk' => 'med',
    'hormone_risk' => undef,
    'notes' => 'Large predatory wild fish (tuna, swordfish) accumulate mercury; choose smaller species.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'organic_certified',
    'attribute' => 'production',
    'citation' => 'Baranski M, Srednicka-Tober D, Volakakis N, et al. Higher antioxidant and lower cadmium concentrations and lower incidence of pesticide residues in organically grown crops. Br J Nutr. 2014;112(5):794-811.',
    'ethics_score' => 3,
    'food_category' => 'leafy_greens',
    'heavy_metal_risk' => 'low',
    'hormone_risk' => undef,
    'notes' => 'Pesticide residues ~4x less frequent in organic crops; lower cadmium.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'low'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'conventional',
    'attribute' => 'production',
    'citation' => 'Environmental Working Group. 2024 Shopper\'s Guide to Pesticides in Produce (analysis of USDA Pesticide Data Program results).',
    'ethics_score' => 2,
    'food_category' => 'leafy_greens',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Spinach/kale/collards rank among highest multi-residue produce.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'high'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'conventional',
    'attribute' => 'production',
    'citation' => 'USDA Agricultural Marketing Service. Pesticide Data Program Annual Summary, Calendar Year 2022; EWG 2024 Shopper\'s Guide.',
    'ethics_score' => 2,
    'food_category' => 'berries',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Strawberries/blueberries frequently carry multiple residues.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'high'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'organic_certified',
    'attribute' => 'production',
    'citation' => 'Baranski M et al. Br J Nutr. 2014;112(5):794-811.',
    'ethics_score' => 3,
    'food_category' => 'berries',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Organic berries markedly fewer residues; higher polyphenols reported.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'low'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'conventional',
    'attribute' => 'production',
    'citation' => 'USDA Agricultural Marketing Service. Pesticide Data Program Annual Summary, Calendar Year 2022.',
    'ethics_score' => 2,
    'food_category' => 'apples',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Apples consistently show multiple residues (e.g., diphenylamine post-harvest).',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'high'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'gmo',
    'attribute' => 'gmo',
    'citation' => 'National Academies of Sciences, Engineering, and Medicine. Genetically Engineered Crops: Experiences and Prospects. Washington DC: The National Academies Press; 2016.',
    'ethics_score' => 2,
    'food_category' => 'corn',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'No substantiated nutrition or safety difference; herbicide-tolerant traits linked to higher glyphosate use.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'med'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'gmo',
    'attribute' => 'gmo',
    'citation' => 'National Academies of Sciences, Engineering, and Medicine. Genetically Engineered Crops: Experiences and Prospects. 2016.',
    'ethics_score' => 2,
    'food_category' => 'soy',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'No substantiated nutrition or safety difference; herbicide-tolerant traits linked to higher glyphosate use.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => 'med'
  },
  {
    'antibiotic_risk' => undef,
    'attr_value' => 'local',
    'attribute' => 'local',
    'citation' => 'Edwards-Jones G. Does eating local food reduce the environmental impact of food production and enhance consumer health? Proc Nutr Soc. 2010;69(4):582-591.',
    'ethics_score' => 4,
    'food_category' => 'any',
    'heavy_metal_risk' => undef,
    'hormone_risk' => undef,
    'notes' => 'Within 160 km. Shorter supply chains; environmental benefit depends on production method more than distance.',
    'nutrient_adj_json' => undef,
    'pesticide_risk' => undef
  }
]
 };

sub rows { return [ map { +{%$_} } @ROWS ] }

1;
