#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#  ---------------------------------------------------------------------
#
#  _____    _      _              _         _____ _____
# | ____|__| | ___| |_      _____(_)___ ___|  ___| ____|
# |  _| / _` |/ _ \ \ \ /\ / / _ \ / __/ __| |_  |  _|
# | |__| (_| |  __/ |\ V  V /  __/ \__ \__ \  _| | |___
# |_____\__,_|\___|_| \_/\_/ \___|_|___/___/_|   |_____|
#
#
#  Unit of Strength of Materials and Structural Analysis
#  University of Innsbruck,
#  2017 - today
#
#  This file is part of EdelweissFE.
#
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#
#  The full text of the license can be found in the file LICENSE.md at
#  the top level directory of EdelweissFE.
#  ---------------------------------------------------------------------
# Created on Mon Oct 13 2026

# @author: Luka Mitrovic

from dataclasses import dataclass

import numpy as np

from edelweissfe.config.phenomena import getFieldSize
from edelweissfe.constraints.base.constraintbase import ConstraintBase
from edelweissfe.journal.journal import Journal
from edelweissfe.models.femodel import FEModel
from edelweissfe.models.meshdependent import MeshDependent
from edelweissfe.sets.nodeset import NodeSet
from edelweissfe.timesteppers.timestep import TimeStep
from edelweissfe.utils.schema import buildSchemaFromOptions, schemaField

"""
A penalty based bilateral constraint which enforces zero displacement along a fixed direction,
i.e. u . n = 0 for every node of a node set. This is a symmetry plane with an arbitrary,
non-axis-aligned unit normal n: for example the oblique face of a cylindrical sector model,
where a plain Dirichlet condition on a single component cannot express the condition.

In contrast to :mod:`~edelweissfe.constraints.nodetorigidsurfacepenalty`, this constraint is
bilateral: it penalizes motion to both sides of the plane.
"""


@dataclass(frozen=True)
class PlaneSymmetryPenaltySchema:
    """The options this constraint accepts, owned by this module and never mutated from outside
    it.

    Each required field is declared ``required=True``, but is still given a ``default=None`` so
    that the schema remains constructible on its own; ``buildSchemaFromOptions`` still enforces
    that an ``.inp`` file supplies each.
    """

    field: str | None = schemaField(
        description="The field this constraint acts on.", dtype=str, default=None, required=True
    )
    nx: float | None = schemaField(
        description="x component of the plane normal.", dtype=float, default=None, required=True
    )
    ny: float | None = schemaField(
        description="y component of the plane normal.", dtype=float, default=None, required=True
    )
    nz: float = schemaField(description="z component of the plane normal (0.0 for 2d).", dtype=float, default=0.0)
    penalty: float | None = schemaField(
        description="The numerical penalty value.", dtype=float, default=None, required=True
    )
    nSet: str | None = schemaField(
        description="The node set to be constrained.", dtype=str, default=None, required=True
    )


class Constraint(ConstraintBase, MeshDependent):
    """A penalty based bilateral symmetry plane constraint: u . n = 0 along a fixed unit normal
    n for every node of a node set.

    Parameters
    ----------
    name
        The name of the constraint.
    model
        The model tree.
    nSet
        The node set to be constrained.
    configuration
        The options this constraint accepts; see :class:`PlaneSymmetryPenaltySchema`.
    """

    #: Option schema for this constraint, per OptionSchemaProvider.
    schema = PlaneSymmetryPenaltySchema

    #: Carries nothing from one increment to the next.
    checkpointedState = {}

    def __init__(
        self,
        name: str,
        model: FEModel,
        nSet: NodeSet,
        *,
        configuration: PlaneSymmetryPenaltySchema = PlaneSymmetryPenaltySchema(),
    ):
        super().__init__(name, model)

        self.theField = configuration.field
        self.sizeField = getFieldSize(self.theField, model.domainSize)

        normal = np.array([configuration.nx, configuration.ny, configuration.nz][: self.sizeField])
        norm = np.linalg.norm(normal)
        if norm < 1e-12:
            raise ValueError(f"constraint {name}: the plane normal has zero length")
        self.normal = normal / norm

        self.penalty = configuration.penalty
        self._nodes = nSet

        self.active = True

        self._lastSeenTopologyVersion = model.topology.version
        model.topology.registerMeshDependent(self)
        self._rebuildDerivedState()

    @classmethod
    def fromConstraintDefinition(
        cls, name: str, definition: dict, model: FEModel, journal: "Journal" = None
    ) -> "Constraint":
        """Build this constraint from a parsed ``*constraint`` definition. See
        :class:`~edelweissfe.constraints.base.constraintbase.ConstraintBase` for why this is
        separate from ``__init__``."""
        configuration = buildSchemaFromOptions(cls.schema, definition)
        return cls(name, model, model.nodeSets[configuration.nSet], configuration=configuration)

    def _rebuildDerivedState(self):
        """(Re)derive every quantity sized to the constrained node set from its *current* size.
        Called once at construction and again from :meth:`refresh` whenever a topology change
        (e.g. by AMR) touched the node set."""

        self._nNodes = len(self._nodes)
        self._nDof = self.sizeField * self._nNodes

        self._fieldsOnNodes = [
            [
                self.theField,
            ]
        ] * self._nNodes

    @property
    def nodes(self) -> list:
        return self._nodes

    @property
    def fieldsOnNodes(self) -> list:
        return self._fieldsOnNodes

    @property
    def nDof(self) -> int:
        return self._nDof

    def refresh(self, model: FEModel, change) -> bool:
        """Recompute the node-set-sized derived state (see :meth:`_rebuildDerivedState`) if a
        topology change touched the constrained node set; see
        :class:`~edelweissfe.models.meshdependent.MeshDependent`."""

        if not change.touchesNodeSet(self._nodes.name):
            return False
        self._rebuildDerivedState()
        return True

    def _penaltyForces(self, U_np: np.ndarray, PExt: np.ndarray):
        """Accumulate the bilateral penalty forces -penalty * (u . n) * n into ``PExt``,
        using strided in-place slices so views are never copied."""

        s = self.sizeField
        projection = np.zeros(self._nNodes)
        for c in range(s):
            projection += U_np[c::s] * self.normal[c]
        for c in range(s):
            PExt[c::s] -= self.penalty * projection * self.normal[c]
        return projection

    def applyConstraint(
        self,
        U_np: np.ndarray,
        dU: np.ndarray,
        PExt: np.ndarray,
        K: np.ndarray,
        timeStep: TimeStep,
    ):
        if not self.active:
            return

        self._penaltyForces(U_np, PExt)

        s = self.sizeField
        nnT = self.penalty * np.outer(self.normal, self.normal)
        for i in range(self._nNodes):
            K[i * s : (i + 1) * s, i * s : (i + 1) * s] += nnT

    def applyConstraintExplicit(
        self,
        U_np: np.ndarray,
        dU: np.ndarray,
        PExt: np.ndarray,
        timeStep: TimeStep,
    ):
        """Force-only evaluation for explicit solvers: no tangent is assembled, so the
        (node set sized) dummy tangent of the default implementation is never allocated."""

        if not self.active:
            return

        self._penaltyForces(U_np, PExt)
