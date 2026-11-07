"""Corrected CompanyX MILP; original DES, production timing and solvers retained.

Lost sales use one unmet-demand penalty per forecast unit and date. Backorders
retain their daily/terminal penalties. This remains a weighted objective, not a
lexicographic guarantee that every real order dominates every forecast tradeoff.
"""

MODEL_VERSION = 'companyx.milp.all-sku-direct-resale.v3.20261105'
