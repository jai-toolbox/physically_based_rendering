tbool :: s32;
TFALSE :: cast(tbool) 0;
TTRUE  :: cast(tbool) 1;

TANGENT_SPACE_PI :: 3.1415926535897932384626433832795;
INTERNAL_RND_SORT_SEED :: cast(u32) 39871946;
FLT_MIN :: 1.1754943508222875e-38;

MARK_DEGENERATE    :: 1;
QUAD_ONE_DEGEN_TRI :: 2;
GROUP_WITH_ANY     :: 4;
ORIENT_PRESERVING  :: 8;

Tangent_Space_Context :: struct {
    m_pInterface: *Tangent_Space_Interface;
    m_pUserData: *void;
}

Tangent_Get_Num_Faces :: #type (pContext: *Tangent_Space_Context) -> s32;
Tangent_Get_Num_Vertices_Of_Face :: #type (pContext: *Tangent_Space_Context, iFace: s32) -> s32;
Tangent_Get_Position :: #type (pContext: *Tangent_Space_Context, fvPosOut: *float, iFace: s32, iVert: s32);
Tangent_Get_Normal :: #type (pContext: *Tangent_Space_Context, fvNormOut: *float, iFace: s32, iVert: s32);
Tangent_Get_TexCoord :: #type (pContext: *Tangent_Space_Context, fvTexcOut: *float, iFace: s32, iVert: s32);
Tangent_Set_TSpace_Basic :: #type (pContext: *Tangent_Space_Context, fvTangent: *float, fSign: float, iFace: s32, iVert: s32);
Tangent_Set_TSpace :: #type (
    pContext: *Tangent_Space_Context,
    fvTangent: *float,
    fvBiTangent: *float,
    fMagS: float,
    fMagT: float,
    bIsOrientationPreserving: tbool,
    iFace: s32,
    iVert: s32
);

// probably don't do this anymore.

Tangent_Space_Interface :: struct {
    m_getNumFaces: Tangent_Get_Num_Faces;
    m_getNumVerticesOfFace: Tangent_Get_Num_Vertices_Of_Face;
    m_getPosition: Tangent_Get_Position;
    m_getNormal: Tangent_Get_Normal;
    m_getTexCoord: Tangent_Get_TexCoord;
    m_setTSpaceBasic: Tangent_Set_TSpace_Basic;
    m_setTSpace: Tangent_Set_TSpace;
}

SVec3 :: struct {
    x: float;
    y: float;
    z: float;
}

SSubGroup :: struct {
    iNrFaces: s32;
    pTriMembers: *s32;
}

SGroup :: struct {
    iNrFaces: s32;
    pFaceIndices: *s32;
    iVertexRepresentitive: s32;
    bOrientPreservering: tbool;
}

STriInfo :: struct {
    FaceNeighbors: [3] s32;
    AssignedGroup: [3] *SGroup;

    vOs: SVec3;
    vOt: SVec3;
    fMagS: float;
    fMagT: float;

    iOrgFaceNumber: s32;
    iFlag: s32;
    iTSpacesOffs: s32;
    vert_num: [4] u8;
}

STSpace :: struct {
    vOs: SVec3;
    fMagS: float;
    vOt: SVec3;
    fMagT: float;
    iCounter: s32;
    bOrient: tbool;
}

STmpVert :: struct {
    vert: [3] float;
    index: s32;
}

SEdge :: struct {
    i0: s32;
    i1: s32;
    f:  s32;
}

veq :: (v1: SVec3, v2: SVec3) -> tbool {
    if v1.x == v2.x && v1.y == v2.y && v1.z == v2.z return TTRUE;
    return TFALSE;
}

vadd :: (v1: SVec3, v2: SVec3) -> SVec3 {
    return .{v1.x + v2.x, v1.y + v2.y, v1.z + v2.z};
}

vsub :: (v1: SVec3, v2: SVec3) -> SVec3 {
    return .{v1.x - v2.x, v1.y - v2.y, v1.z - v2.z};
}

vscale :: (fS: float, v: SVec3) -> SVec3 {
    return .{fS * v.x, fS * v.y, fS * v.z};
}

LengthSquared :: (v: SVec3) -> float {
    return v.x*v.x + v.y*v.y + v.z*v.z;
}

Length :: (v: SVec3) -> float {
    return sqrt(LengthSquared(v));
}

Normalize :: (v: SVec3) -> SVec3 {
    return vscale(1.0 / Length(v), v);
}

vdot :: (v1: SVec3, v2: SVec3) -> float {
    return v1.x*v2.x + v1.y*v2.y + v1.z*v2.z;
}

NotZero :: (fX: float) -> tbool {
    if abs(fX) > FLT_MIN return TTRUE;
    return TFALSE;
}

VNotZero :: (v: SVec3) -> tbool {
    if NotZero(v.x) != 0 || NotZero(v.y) != 0 || NotZero(v.z) != 0 return TTRUE;
    return TFALSE;
}

MakeIndex :: (iFace: s32, iVert: s32) -> s32 {
    return (iFace << 2) | (iVert & 0x3);
}

IndexToData :: (piFace: *s32, piVert: *s32, iIndexIn: s32) {
    piVert.* = iIndexIn & 0x3;
    piFace.* = iIndexIn >> 2;
}

AvgTSpace :: (pTS0: *STSpace, pTS1: *STSpace) -> STSpace {
    ts_res: STSpace;

    if pTS0.fMagS == pTS1.fMagS && pTS0.fMagT == pTS1.fMagT &&
       veq(pTS0.vOs, pTS1.vOs) != 0 && veq(pTS0.vOt, pTS1.vOt) != 0 {
        ts_res.fMagS = pTS0.fMagS;
        ts_res.fMagT = pTS0.fMagT;
        ts_res.vOs = pTS0.vOs;
        ts_res.vOt = pTS0.vOt;
    } else {
        ts_res.fMagS = 0.5 * (pTS0.fMagS + pTS1.fMagS);
        ts_res.fMagT = 0.5 * (pTS0.fMagT + pTS1.fMagT);
        ts_res.vOs = vadd(pTS0.vOs, pTS1.vOs);
        ts_res.vOt = vadd(pTS0.vOt, pTS1.vOt);
        if VNotZero(ts_res.vOs) != 0 ts_res.vOs = Normalize(ts_res.vOs);
        if VNotZero(ts_res.vOt) != 0 ts_res.vOt = Normalize(ts_res.vOt);
    }

    return ts_res;
}

generate_tangent_space_default :: (pContext: *Tangent_Space_Context) -> tbool {
    return generate_tangent_space(pContext, 180.0);
}

generate_tangent_space :: (pContext: *Tangent_Space_Context, fAngularThreshold: float) -> tbool {
    if pContext == null || pContext.m_pInterface == null return TFALSE;
    if pContext.m_pInterface.m_getNumFaces == null ||
       pContext.m_pInterface.m_getNumVerticesOfFace == null ||
       pContext.m_pInterface.m_getPosition == null ||
       pContext.m_pInterface.m_getNormal == null ||
       pContext.m_pInterface.m_getTexCoord == null {
        return TFALSE;
    }

    iNrFaces := pContext.m_pInterface.m_getNumFaces(pContext);
    fThresCos := cast(float) cos((fAngularThreshold * cast(float) TANGENT_SPACE_PI) / 180.0);

    iNrTrianglesIn: s32 = 0;
    f: s32 = 0;
    while f < iNrFaces {
        verts := pContext.m_pInterface.m_getNumVerticesOfFace(pContext, f);
        if verts == 3 iNrTrianglesIn += 1;
        else if verts == 4 iNrTrianglesIn += 2;
        f += 1;
    }
    if iNrTrianglesIn <= 0 return TFALSE;

    piTriListIn: [..] s32;
    pTriInfos: [..] STriInfo;
    psTspace: [..] STSpace;
    pGroups: [..] SGroup;
    piGroupTrianglesBuffer: [..] s32;
    defer {
        array_free(piTriListIn);
        array_free(pTriInfos);
        array_free(psTspace);
        array_free(pGroups);
        array_free(piGroupTrianglesBuffer);
    }

    array_resize(*piTriListIn, 3 * iNrTrianglesIn);
    array_resize(*pTriInfos, iNrTrianglesIn);

    iNrTSPaces := GenerateInitialVerticesIndexList(pTriInfos, piTriListIn, pContext, iNrTrianglesIn);
    GenerateSharedVerticesIndexList(piTriListIn, pContext, iNrTrianglesIn);

    iTotTris := iNrTrianglesIn;
    iDegenTriangles: s32 = 0;
    t: s32 = 0;
    while t < iTotTris {
        i0 := piTriListIn[t*3+0];
        i1 := piTriListIn[t*3+1];
        i2 := piTriListIn[t*3+2];
        p0 := GetPosition(pContext, i0);
        p1 := GetPosition(pContext, i1);
        p2 := GetPosition(pContext, i2);
        if veq(p0, p1) != 0 || veq(p0, p2) != 0 || veq(p1, p2) != 0 {
            pTriInfos[t].iFlag |= MARK_DEGENERATE;
            iDegenTriangles += 1;
        }
        t += 1;
    }
    iNrTrianglesIn = iTotTris - iDegenTriangles;

    DegenPrologue(pTriInfos, piTriListIn, iNrTrianglesIn, iTotTris);
    InitTriInfo(pTriInfos, piTriListIn, pContext, iNrTrianglesIn);

    iNrMaxGroups := iNrTrianglesIn * 3;
    array_resize(*pGroups, iNrMaxGroups);
    array_resize(*piGroupTrianglesBuffer, iNrTrianglesIn * 3);
    iNrActiveGroups := Build4RuleGroups(pTriInfos, pGroups, piGroupTrianglesBuffer, piTriListIn, iNrTrianglesIn);

    array_resize(*psTspace, iNrTSPaces);
    t = 0;
    while t < iNrTSPaces {
        psTspace[t] = .{};
        psTspace[t].vOs = .{1.0, 0.0, 0.0}; psTspace[t].fMagS = 1.0;
        psTspace[t].vOt = .{0.0, 1.0, 0.0}; psTspace[t].fMagT = 1.0;
        t += 1;
    }

    bRes := GenerateTSpaces(psTspace, pTriInfos, pGroups, iNrActiveGroups, piTriListIn, fThresCos, pContext);
    if bRes == 0 return TFALSE;

    DegenEpilogue(psTspace, pTriInfos, piTriListIn, pContext, iNrTrianglesIn, iTotTris);

    index: s32 = 0;
    f = 0;
    while f < iNrFaces {
        verts := pContext.m_pInterface.m_getNumVerticesOfFace(pContext, f);
        if verts == 3 || verts == 4 {
            i: s32 = 0;
            while i < verts {
                pTSpace := *psTspace[index];
                tang := float.[pTSpace.vOs.x, pTSpace.vOs.y, pTSpace.vOs.z];
                bitang := float.[pTSpace.vOt.x, pTSpace.vOt.y, pTSpace.vOt.z];
                if pContext.m_pInterface.m_setTSpace != null {
                    pContext.m_pInterface.m_setTSpace(pContext, tang.data, bitang.data, pTSpace.fMagS, pTSpace.fMagT, pTSpace.bOrient, f, i);
                }
                if pContext.m_pInterface.m_setTSpaceBasic != null {
                    sign := 1.0;
                    if pTSpace.bOrient != TTRUE sign = -1.0;
                    pContext.m_pInterface.m_setTSpaceBasic(pContext, tang.data, sign, f, i);
                }
                index += 1;
                i += 1;
            }
        }
        f += 1;
    }

    return TTRUE;
}

FindGridCell :: (fMin: float, fMax: float, fVal: float) -> s32 {
    fIndex := cast(float) 2048 * ((fVal - fMin) / (fMax - fMin));
    iIndex := cast(s32) fIndex;
    if iIndex < 2048 {
        if iIndex >= 0 return iIndex;
        return 0;
    }
    return 2048 - 1;
}

GetPosition :: (pContext: *Tangent_Space_Context, index: s32) -> SVec3 {
    iF: s32; iI: s32;
    pos: [3] float;
    IndexToData(*iF, *iI, index);
    pContext.m_pInterface.m_getPosition(pContext, pos.data, iF, iI);
    return .{pos[0], pos[1], pos[2]};
}

GetNormal :: (pContext: *Tangent_Space_Context, index: s32) -> SVec3 {
    iF: s32; iI: s32;
    norm: [3] float;
    IndexToData(*iF, *iI, index);
    pContext.m_pInterface.m_getNormal(pContext, norm.data, iF, iI);
    return .{norm[0], norm[1], norm[2]};
}

GetTexCoord :: (pContext: *Tangent_Space_Context, index: s32) -> SVec3 {
    iF: s32; iI: s32;
    texc: [2] float;
    IndexToData(*iF, *iI, index);
    pContext.m_pInterface.m_getTexCoord(pContext, texc.data, iF, iI);
    return .{texc[0], texc[1], 1.0};
}

CalcTexArea :: (pContext: *Tangent_Space_Context, indices: [] s32) -> float {
    t1 := GetTexCoord(pContext, indices[0]);
    t2 := GetTexCoord(pContext, indices[1]);
    t3 := GetTexCoord(pContext, indices[2]);

    t21x := t2.x - t1.x;
    t21y := t2.y - t1.y;
    t31x := t3.x - t1.x;
    t31y := t3.y - t1.y;
    fSignedAreaSTx2 := t21x*t31y - t21y*t31x;

    if fSignedAreaSTx2 < 0 return -fSignedAreaSTx2;
    return fSignedAreaSTx2;
}

GenerateInitialVerticesIndexList :: (pTriInfos: [] STriInfo, piTriList_out: [] s32, pContext: *Tangent_Space_Context, iNrTrianglesIn: s32) -> s32 {
    iTSpacesOffs: s32 = 0;
    iDstTriIndex: s32 = 0;
    f: s32 = 0;
    while f < pContext.m_pInterface.m_getNumFaces(pContext) {
        verts := pContext.m_pInterface.m_getNumVerticesOfFace(pContext, f);
        if verts != 3 && verts != 4 {
            f += 1;
            continue;
        }

        pTriInfos[iDstTriIndex].iOrgFaceNumber = f;
        pTriInfos[iDstTriIndex].iTSpacesOffs = iTSpacesOffs;

        if verts == 3 {
            pTriInfos[iDstTriIndex].vert_num[0] = 0;
            pTriInfos[iDstTriIndex].vert_num[1] = 1;
            pTriInfos[iDstTriIndex].vert_num[2] = 2;
            piTriList_out[iDstTriIndex*3+0] = MakeIndex(f, 0);
            piTriList_out[iDstTriIndex*3+1] = MakeIndex(f, 1);
            piTriList_out[iDstTriIndex*3+2] = MakeIndex(f, 2);
            iDstTriIndex += 1;
        } else {
            pTriInfos[iDstTriIndex+1].iOrgFaceNumber = f;
            pTriInfos[iDstTriIndex+1].iTSpacesOffs = iTSpacesOffs;

            i0 := MakeIndex(f, 0);
            i1 := MakeIndex(f, 1);
            i2 := MakeIndex(f, 2);
            i3 := MakeIndex(f, 3);
            T0 := GetTexCoord(pContext, i0);
            T1 := GetTexCoord(pContext, i1);
            T2 := GetTexCoord(pContext, i2);
            T3 := GetTexCoord(pContext, i3);
            distSQ_02 := LengthSquared(vsub(T2, T0));
            distSQ_13 := LengthSquared(vsub(T3, T1));
            bQuadDiagIs_02: tbool;
            if distSQ_02 < distSQ_13 bQuadDiagIs_02 = TTRUE;
            else if distSQ_13 < distSQ_02 bQuadDiagIs_02 = TFALSE;
            else {
                P0 := GetPosition(pContext, i0);
                P1 := GetPosition(pContext, i1);
                P2 := GetPosition(pContext, i2);
                P3 := GetPosition(pContext, i3);
                pdistSQ_02 := LengthSquared(vsub(P2, P0));
                pdistSQ_13 := LengthSquared(vsub(P3, P1));
                if pdistSQ_13 < pdistSQ_02 bQuadDiagIs_02 = TFALSE;
                else bQuadDiagIs_02 = TTRUE;
            }

            if bQuadDiagIs_02 != 0 {
                pTriInfos[iDstTriIndex].vert_num[0] = 0;
                pTriInfos[iDstTriIndex].vert_num[1] = 1;
                pTriInfos[iDstTriIndex].vert_num[2] = 2;
                piTriList_out[iDstTriIndex*3+0] = i0;
                piTriList_out[iDstTriIndex*3+1] = i1;
                piTriList_out[iDstTriIndex*3+2] = i2;
                iDstTriIndex += 1;

                pTriInfos[iDstTriIndex].vert_num[0] = 0;
                pTriInfos[iDstTriIndex].vert_num[1] = 2;
                pTriInfos[iDstTriIndex].vert_num[2] = 3;
                piTriList_out[iDstTriIndex*3+0] = i0;
                piTriList_out[iDstTriIndex*3+1] = i2;
                piTriList_out[iDstTriIndex*3+2] = i3;
                iDstTriIndex += 1;
            } else {
                pTriInfos[iDstTriIndex].vert_num[0] = 0;
                pTriInfos[iDstTriIndex].vert_num[1] = 1;
                pTriInfos[iDstTriIndex].vert_num[2] = 3;
                piTriList_out[iDstTriIndex*3+0] = i0;
                piTriList_out[iDstTriIndex*3+1] = i1;
                piTriList_out[iDstTriIndex*3+2] = i3;
                iDstTriIndex += 1;

                pTriInfos[iDstTriIndex].vert_num[0] = 1;
                pTriInfos[iDstTriIndex].vert_num[1] = 2;
                pTriInfos[iDstTriIndex].vert_num[2] = 3;
                piTriList_out[iDstTriIndex*3+0] = i1;
                piTriList_out[iDstTriIndex*3+1] = i2;
                piTriList_out[iDstTriIndex*3+2] = i3;
                iDstTriIndex += 1;
            }
        }

        iTSpacesOffs += verts;
        f += 1;
    }

    t: s32 = 0;
    while t < iNrTrianglesIn {
        pTriInfos[t].iFlag = 0;
        t += 1;
    }

    return iTSpacesOffs;
}

GenerateSharedVerticesIndexList :: (piTriList_in_and_out: [] s32, pContext: *Tangent_Space_Context, iNrTrianglesIn: s32) {
    // Equivalent to the reference weld: replace equal position/normal/uv corners
    // by the first representative index found in the triangle list.
    offs: s32 = 0;
    total := iNrTrianglesIn * 3;
    while offs < total {
        index := piTriList_in_and_out[offs];
        vP := GetPosition(pContext, index);
        vN := GetNormal(pContext, index);
        vT := GetTexCoord(pContext, index);

        found := TFALSE;
        found_index := index;
        e: s32 = 0;
        while e <= offs && found == TFALSE {
            index2 := piTriList_in_and_out[e];
            vP2 := GetPosition(pContext, index2);
            vN2 := GetNormal(pContext, index2);
            vT2 := GetTexCoord(pContext, index2);
            if veq(vP, vP2) != 0 && veq(vN, vN2) != 0 && veq(vT, vT2) != 0 {
                found = TTRUE;
                found_index = index2;
            } else {
                e += 1;
            }
        }
        piTriList_in_and_out[offs] = found_index;
        offs += 1;
    }
}

InitTriInfo :: (pTriInfos: [] STriInfo, piTriListIn: [] s32, pContext: *Tangent_Space_Context, iNrTrianglesIn: s32) {
    f: s32 = 0;
    while f < iNrTrianglesIn {
        i: s32 = 0;
        while i < 3 {
            pTriInfos[f].FaceNeighbors[i] = -1;
            pTriInfos[f].AssignedGroup[i] = null;
            i += 1;
        }

        pTriInfos[f].vOs = .{0, 0, 0};
        pTriInfos[f].vOt = .{0, 0, 0};
        pTriInfos[f].fMagS = 0;
        pTriInfos[f].fMagT = 0;
        pTriInfos[f].iFlag |= GROUP_WITH_ANY;
        f += 1;
    }

    f = 0;
    while f < iNrTrianglesIn {
        v1 := GetPosition(pContext, piTriListIn[f*3+0]);
        v2 := GetPosition(pContext, piTriListIn[f*3+1]);
        v3 := GetPosition(pContext, piTriListIn[f*3+2]);
        t1 := GetTexCoord(pContext, piTriListIn[f*3+0]);
        t2 := GetTexCoord(pContext, piTriListIn[f*3+1]);
        t3 := GetTexCoord(pContext, piTriListIn[f*3+2]);

        t21x := t2.x - t1.x;
        t21y := t2.y - t1.y;
        t31x := t3.x - t1.x;
        t31y := t3.y - t1.y;
        d1 := vsub(v2, v1);
        d2 := vsub(v3, v1);

        fSignedAreaSTx2 := t21x*t31y - t21y*t31x;
        vOs := vsub(vscale(t31y, d1), vscale(t21y, d2));
        vOt := vadd(vscale(-t31x, d1), vscale(t21x, d2));

        if fSignedAreaSTx2 > 0 pTriInfos[f].iFlag |= ORIENT_PRESERVING;

        if NotZero(fSignedAreaSTx2) != 0 {
            fAbsArea := abs(fSignedAreaSTx2);
            fLenOs := Length(vOs);
            fLenOt := Length(vOt);
            fS := 1.0;
            if (pTriInfos[f].iFlag & ORIENT_PRESERVING) == 0 fS = -1.0;
            if NotZero(fLenOs) != 0 pTriInfos[f].vOs = vscale(fS / fLenOs, vOs);
            if NotZero(fLenOt) != 0 pTriInfos[f].vOt = vscale(fS / fLenOt, vOt);

            pTriInfos[f].fMagS = fLenOs / fAbsArea;
            pTriInfos[f].fMagT = fLenOt / fAbsArea;
            if NotZero(pTriInfos[f].fMagS) != 0 && NotZero(pTriInfos[f].fMagT) != 0 {
                pTriInfos[f].iFlag &= cast(s32) ~GROUP_WITH_ANY;
            }
        }
        f += 1;
    }

    t: s32 = 0;
    while t < iNrTrianglesIn - 1 {
        if pTriInfos[t].iOrgFaceNumber == pTriInfos[t+1].iOrgFaceNumber {
            bIsDeg_a := ((pTriInfos[t].iFlag & MARK_DEGENERATE) != 0);
            bIsDeg_b := ((pTriInfos[t+1].iFlag & MARK_DEGENERATE) != 0);
            if !bIsDeg_a && !bIsDeg_b {
                bOrientA := ((pTriInfos[t].iFlag & ORIENT_PRESERVING) != 0);
                bOrientB := ((pTriInfos[t+1].iFlag & ORIENT_PRESERVING) != 0);
                if bOrientA != bOrientB {
                    bChooseOrientFirstTri := false;
                    if (pTriInfos[t+1].iFlag & GROUP_WITH_ANY) != 0 {
                        bChooseOrientFirstTri = true;
                    } else {
                        area_indices0 := s32.[piTriListIn[t*3+0], piTriListIn[t*3+1], piTriListIn[t*3+2]];
                        area_indices1 := s32.[piTriListIn[(t+1)*3+0], piTriListIn[(t+1)*3+1], piTriListIn[(t+1)*3+2]];
                        area0 := CalcTexArea(pContext, area_indices0);
                        area1 := CalcTexArea(pContext, area_indices1);
                        if area0 >= area1 bChooseOrientFirstTri = true;
                    }
                    t0 := t + 1;
                    t1 := t;
                    if bChooseOrientFirstTri {
                        t0 = t;
                        t1 = t + 1;
                    }
                    pTriInfos[t1].iFlag &= cast(s32) ~ORIENT_PRESERVING;
                    pTriInfos[t1].iFlag |= (pTriInfos[t0].iFlag & ORIENT_PRESERVING);
                }
            }
            t += 2;
        } else {
            t += 1;
        }
    }

    BuildNeighborsSlow(pTriInfos, piTriListIn, iNrTrianglesIn);
}

BuildNeighborsSlow :: (pTriInfos: [] STriInfo, piTriListIn: [] s32, iNrTrianglesIn: s32) {
    f: s32 = 0;
    while f < iNrTrianglesIn {
        i: s32 = 0;
        while i < 3 {
            i0_a := piTriListIn[f*3+i];
            i1_a := piTriListIn[f*3+((i+1)%3)];
            if i0_a > i1_a {
                tmp := i0_a; i0_a = i1_a; i1_a = tmp;
            }

            f2 := f + 1;
            while f2 < iNrTrianglesIn {
                j: s32 = 0;
                while j < 3 {
                    i0_b := piTriListIn[f2*3+j];
                    i1_b := piTriListIn[f2*3+((j+1)%3)];
                    if i0_b > i1_b {
                        tmp := i0_b; i0_b = i1_b; i1_b = tmp;
                    }
                    if i0_a == i0_b && i1_a == i1_b {
                        pTriInfos[f].FaceNeighbors[i] = f2;
                        pTriInfos[f2].FaceNeighbors[j] = f;
                    }
                    j += 1;
                }
                f2 += 1;
            }
            i += 1;
        }
        f += 1;
    }
}

Build4RuleGroups :: (pTriInfos: [] STriInfo, pGroups: [] SGroup, piGroupTrianglesBuffer: [] s32, piTriListIn: [] s32, iNrTrianglesIn: s32) -> s32 {
    iNrActiveGroups: s32 = 0;
    iOffset: s32 = 0;

    f: s32 = 0;
    while f < iNrTrianglesIn {
        i: s32 = 0;
        while i < 3 {
            if pTriInfos[f].AssignedGroup[i] == null && (pTriInfos[f].iFlag & GROUP_WITH_ANY) == 0 {
                pGroup := *pGroups[iNrActiveGroups];
                pGroup.iNrFaces = 0;
                pGroup.pFaceIndices = *piGroupTrianglesBuffer[iOffset];
                pGroup.iVertexRepresentitive = piTriListIn[f*3+i];
                pGroup.bOrientPreservering = TFALSE;
                if (pTriInfos[f].iFlag & ORIENT_PRESERVING) != 0 pGroup.bOrientPreservering = TTRUE;

                AssignRecur(piTriListIn, pTriInfos, f, pGroup);

                iOffset += pGroup.iNrFaces;
                iNrActiveGroups += 1;
            }
            i += 1;
        }
        f += 1;
    }

    return iNrActiveGroups;
}

AddTriToGroup :: (pGroup: *SGroup, iTriIndex: s32) {
    pGroup.pFaceIndices[pGroup.iNrFaces] = iTriIndex;
    pGroup.iNrFaces += 1;
}

AssignRecur :: (piTriListIn: [] s32, psTriInfos: [] STriInfo, iMyTriIndex: s32, pGroup: *SGroup) -> tbool {
    i: s32 = 0;
    while i < 3 {
        if piTriListIn[iMyTriIndex*3+i] == pGroup.iVertexRepresentitive {
            if psTriInfos[iMyTriIndex].AssignedGroup[i] == null {
                psTriInfos[iMyTriIndex].AssignedGroup[i] = pGroup;
                AddTriToGroup(pGroup, iMyTriIndex);

                iNextTri := psTriInfos[iMyTriIndex].FaceNeighbors[i];
                if iNextTri >= 0 {
                    bOrientA := ((psTriInfos[iMyTriIndex].iFlag & ORIENT_PRESERVING) != 0);
                    bOrientB := ((psTriInfos[iNextTri].iFlag & ORIENT_PRESERVING) != 0);
                    if bOrientA == bOrientB {
                        j: s32 = 0;
                        while j < 3 {
                            if piTriListIn[iNextTri*3+j] == pGroup.iVertexRepresentitive {
                                if psTriInfos[iNextTri].AssignedGroup[j] == null {
                                    AssignRecur(piTriListIn, psTriInfos, iNextTri, pGroup);
                                }
                            }
                            j += 1;
                        }
                    }
                }
            }
        }
        i += 1;
    }
    return TTRUE;
}

GenerateTSpaces :: (
    psTspace: [] STSpace,
    pTriInfos: [] STriInfo,
    pGroups: [] SGroup,
    iNrActiveGroups: s32,
    piTriListIn: [] s32,
    fThresCos: float,
    pContext: *Tangent_Space_Context
) -> tbool {
    iMaxNrFaces: s32 = 0;
    g: s32 = 0;
    while g < iNrActiveGroups {
        if iMaxNrFaces < pGroups[g].iNrFaces iMaxNrFaces = pGroups[g].iNrFaces;
        g += 1;
    }
    if iMaxNrFaces == 0 return TTRUE;

    pSubGroupTspace: [..] STSpace;
    pUniSubGroups: [..] SSubGroup;
    pTmpMembers: [..] s32;
    pUniSubGroupMembers: [..] s32;
    defer {
        array_free(pSubGroupTspace);
        array_free(pUniSubGroups);
        array_free(pTmpMembers);
        array_free(pUniSubGroupMembers);
    }
    array_resize(*pSubGroupTspace, iMaxNrFaces);
    array_resize(*pUniSubGroups, iMaxNrFaces);
    array_resize(*pTmpMembers, iMaxNrFaces);
    array_resize(*pUniSubGroupMembers, iMaxNrFaces * iMaxNrFaces);

    g = 0;
    while g < iNrActiveGroups {
        pGroup := *pGroups[g];
        iUniqueSubGroups: s32 = 0;

        ii: s32 = 0;
        while ii < pGroup.iNrFaces {
            f := pGroup.pFaceIndices[ii];
            index: s32 = -1;
            if pTriInfos[f].AssignedGroup[0] == pGroup index = 0;
            else if pTriInfos[f].AssignedGroup[1] == pGroup index = 1;
            else if pTriInfos[f].AssignedGroup[2] == pGroup index = 2;

            iVertIndex := piTriListIn[f*3+index];
            n := GetNormal(pContext, iVertIndex);
            vOs := vsub(pTriInfos[f].vOs, vscale(vdot(n, pTriInfos[f].vOs), n));
            vOt := vsub(pTriInfos[f].vOt, vscale(vdot(n, pTriInfos[f].vOt), n));
            if VNotZero(vOs) != 0 vOs = Normalize(vOs);
            if VNotZero(vOt) != 0 vOt = Normalize(vOt);

            iOF_1 := pTriInfos[f].iOrgFaceNumber;
            iMembers: s32 = 0;
            j: s32 = 0;
            while j < pGroup.iNrFaces {
                t := pGroup.pFaceIndices[j];
                iOF_2 := pTriInfos[t].iOrgFaceNumber;

                vOs2 := vsub(pTriInfos[t].vOs, vscale(vdot(n, pTriInfos[t].vOs), n));
                vOt2 := vsub(pTriInfos[t].vOt, vscale(vdot(n, pTriInfos[t].vOt), n));
                if VNotZero(vOs2) != 0 vOs2 = Normalize(vOs2);
                if VNotZero(vOt2) != 0 vOt2 = Normalize(vOt2);

                bAny := (((pTriInfos[f].iFlag | pTriInfos[t].iFlag) & GROUP_WITH_ANY) != 0);
                bSameOrgFace := iOF_1 == iOF_2;
                fCosS := vdot(vOs, vOs2);
                fCosT := vdot(vOt, vOt2);

                if bAny || bSameOrgFace || (fCosS > fThresCos && fCosT > fThresCos) {
                    pTmpMembers[iMembers] = t;
                    iMembers += 1;
                }
                j += 1;
            }

            if iMembers > 1 {
                QuickSort(pTmpMembers, 0, iMembers - 1, INTERNAL_RND_SORT_SEED);
            }

            l: s32 = 0;
            bFound := TFALSE;
            while l < iUniqueSubGroups && bFound == TFALSE {
                tmp_group: SSubGroup;
                tmp_group.iNrFaces = iMembers;
                tmp_group.pTriMembers = pTmpMembers.data;
                bFound = CompareSubGroups(*tmp_group, *pUniSubGroups[l]);
                if bFound == TFALSE l += 1;
            }

            if bFound == TFALSE {
                base := iUniqueSubGroups * iMaxNrFaces;
                pUniSubGroups[iUniqueSubGroups].iNrFaces = iMembers;
                pUniSubGroups[iUniqueSubGroups].pTriMembers = *pUniSubGroupMembers[base];
                copy_i: s32 = 0;
                while copy_i < iMembers {
                    pUniSubGroupMembers[base + copy_i] = pTmpMembers[copy_i];
                    copy_i += 1;
                }
                pSubGroupTspace[iUniqueSubGroups] = EvalTspace(pTmpMembers, iMembers, piTriListIn, pTriInfos, pContext, pGroup.iVertexRepresentitive);
                l = iUniqueSubGroups;
                iUniqueSubGroups += 1;
            }

            iOffs := pTriInfos[f].iTSpacesOffs;
            iVert := cast(s32) pTriInfos[f].vert_num[index];
            pTS_out := *psTspace[iOffs + iVert];
            if pTS_out.iCounter == 1 {
                pTS_out.* = AvgTSpace(pTS_out, *pSubGroupTspace[l]);
                pTS_out.iCounter = 2;
                pTS_out.bOrient = pGroup.bOrientPreservering;
            } else {
                pTS_out.* = pSubGroupTspace[l];
                pTS_out.iCounter = 1;
                pTS_out.bOrient = pGroup.bOrientPreservering;
            }

            ii += 1;
        }

        g += 1;
    }

    return TTRUE;
}

EvalTspace :: (face_indices: [] s32, iFaces: s32, piTriListIn: [] s32, pTriInfos: [] STriInfo, pContext: *Tangent_Space_Context, iVertexRepresentitive: s32) -> STSpace {
    res: STSpace;
    res.vOs = .{0, 0, 0};
    res.vOt = .{0, 0, 0};
    res.fMagS = 0;
    res.fMagT = 0;
    fAngleSum: float = 0;

    face: s32 = 0;
    while face < iFaces {
        f := face_indices[face];

        if (pTriInfos[f].iFlag & GROUP_WITH_ANY) == 0 {
            i: s32 = -1;
            if piTriListIn[3*f+0] == iVertexRepresentitive i = 0;
            else if piTriListIn[3*f+1] == iVertexRepresentitive i = 1;
            else if piTriListIn[3*f+2] == iVertexRepresentitive i = 2;

            index := piTriListIn[3*f+i];
            n := GetNormal(pContext, index);
            vOs := vsub(pTriInfos[f].vOs, vscale(vdot(n, pTriInfos[f].vOs), n));
            vOt := vsub(pTriInfos[f].vOt, vscale(vdot(n, pTriInfos[f].vOt), n));
            if VNotZero(vOs) != 0 vOs = Normalize(vOs);
            if VNotZero(vOt) != 0 vOt = Normalize(vOt);

            next_i := i + 1;
            if next_i >= 3 next_i = 0;
            prev_i := i - 1;
            if prev_i < 0 prev_i = 2;
            i2 := piTriListIn[3*f + next_i];
            i1 := piTriListIn[3*f + i];
            i0 := piTriListIn[3*f + prev_i];

            p0 := GetPosition(pContext, i0);
            p1 := GetPosition(pContext, i1);
            p2 := GetPosition(pContext, i2);
            v1 := vsub(p0, p1);
            v2 := vsub(p2, p1);

            v1 = vsub(v1, vscale(vdot(n, v1), n));
            if VNotZero(v1) != 0 v1 = Normalize(v1);
            v2 = vsub(v2, vscale(vdot(n, v2), n));
            if VNotZero(v2) != 0 v2 = Normalize(v2);

            fCos := vdot(v1, v2);
            if fCos > 1 fCos = 1;
            if fCos < -1 fCos = -1;
            fAngle := cast(float) acos(fCos);
            fMagS := pTriInfos[f].fMagS;
            fMagT := pTriInfos[f].fMagT;

            res.vOs = vadd(res.vOs, vscale(fAngle, vOs));
            res.vOt = vadd(res.vOt, vscale(fAngle, vOt));
            res.fMagS += fAngle * fMagS;
            res.fMagT += fAngle * fMagT;
            fAngleSum += fAngle;
        }

        face += 1;
    }

    if VNotZero(res.vOs) != 0 res.vOs = Normalize(res.vOs);
    if VNotZero(res.vOt) != 0 res.vOt = Normalize(res.vOt);
    if fAngleSum > 0 {
        res.fMagS /= fAngleSum;
        res.fMagT /= fAngleSum;
    }

    return res;
}

CompareSubGroups :: (pg1: *SSubGroup, pg2: *SSubGroup) -> tbool {
    if pg1.iNrFaces != pg2.iNrFaces return TFALSE;
    i: s32 = 0;
    while i < pg1.iNrFaces {
        if pg1.pTriMembers[i] != pg2.pTriMembers[i] return TFALSE;
        i += 1;
    }
    return TTRUE;
}

QuickSort :: (pSortBuffer: [] s32, iLeft: s32, iRight: s32, uSeed: u32) {
    if iLeft >= iRight return;

    t := uSeed & 31;
    pivot_index := iLeft + cast(s32) ((cast(u32)(iRight - iLeft + 1) * t) >> 5);
    pivot := pSortBuffer[pivot_index];
    iL := iLeft;
    iR := iRight;

    while iL <= iR {
        while pSortBuffer[iL] < pivot iL += 1;
        while pSortBuffer[iR] > pivot iR -= 1;
        if iL <= iR {
            tmp := pSortBuffer[iL];
            pSortBuffer[iL] = pSortBuffer[iR];
            pSortBuffer[iR] = tmp;
            iL += 1;
            iR -= 1;
        }
    }

    if iLeft < iR QuickSort(pSortBuffer, iLeft, iR, uSeed + 1);
    if iL < iRight QuickSort(pSortBuffer, iL, iRight, uSeed + 1);
}

DegenPrologue :: (pTriInfos: [] STriInfo, piTriList_out: [] s32, iNrTrianglesIn: s32, iTotTris: s32) {
    t: s32 = 0;
    while t < iTotTris - 1 {
        iFO_a := pTriInfos[t].iOrgFaceNumber;
        iFO_b := pTriInfos[t+1].iOrgFaceNumber;
        if iFO_a == iFO_b {
            bIsDeg_a := ((pTriInfos[t].iFlag & MARK_DEGENERATE) != 0);
            bIsDeg_b := ((pTriInfos[t+1].iFlag & MARK_DEGENERATE) != 0);
            if bIsDeg_a != bIsDeg_b {
                pTriInfos[t].iFlag |= QUAD_ONE_DEGEN_TRI;
                pTriInfos[t+1].iFlag |= QUAD_ONE_DEGEN_TRI;
            }
            t += 2;
        } else {
            t += 1;
        }
    }

    iNextGoodTriangleSearchIndex: s32 = 1;
    bStillFindingGoodOnes := TTRUE;
    t = 0;
    while t < iNrTrianglesIn && bStillFindingGoodOnes != 0 {
        bIsGood := ((pTriInfos[t].iFlag & MARK_DEGENERATE) == 0);
        if bIsGood {
            if iNextGoodTriangleSearchIndex < t + 2 {
                iNextGoodTriangleSearchIndex = t + 2;
            }
        } else {
            bJustADegenerate := TTRUE;
            while bJustADegenerate != 0 && iNextGoodTriangleSearchIndex < iTotTris {
                bSearchIsGood := ((pTriInfos[iNextGoodTriangleSearchIndex].iFlag & MARK_DEGENERATE) == 0);
                if bSearchIsGood bJustADegenerate = TFALSE;
                else iNextGoodTriangleSearchIndex += 1;
            }

            t0 := t;
            t1 := iNextGoodTriangleSearchIndex;
            iNextGoodTriangleSearchIndex += 1;

            if bJustADegenerate == TFALSE {
                i: s32 = 0;
                while i < 3 {
                    index := piTriList_out[t0*3+i];
                    piTriList_out[t0*3+i] = piTriList_out[t1*3+i];
                    piTriList_out[t1*3+i] = index;
                    i += 1;
                }

                tri_info := pTriInfos[t0];
                pTriInfos[t0] = pTriInfos[t1];
                pTriInfos[t1] = tri_info;
            } else {
                bStillFindingGoodOnes = TFALSE;
            }
        }

        if bStillFindingGoodOnes != 0 t += 1;
    }
}

DegenEpilogue :: (psTspace: [] STSpace, pTriInfos: [] STriInfo, piTriListIn: [] s32, pContext: *Tangent_Space_Context, iNrTrianglesIn: s32, iTotTris: s32) {
    t: s32 = iNrTrianglesIn;
    while t < iTotTris {
        bSkip := ((pTriInfos[t].iFlag & QUAD_ONE_DEGEN_TRI) != 0);
        if bSkip {
            t += 1;
            continue;
        }

        i: s32 = 0;
        while i < 3 {
            index1 := piTriListIn[t*3+i];
            bNotFound := TTRUE;
            j: s32 = 0;
            while bNotFound != 0 && j < 3 * iNrTrianglesIn {
                index2 := piTriListIn[j];
                if index1 == index2 bNotFound = TFALSE;
                else j += 1;
            }

            if bNotFound == TFALSE {
                iTri := j / 3;
                iVert := j % 3;
                iSrcVert := cast(s32) pTriInfos[iTri].vert_num[iVert];
                iSrcOffs := pTriInfos[iTri].iTSpacesOffs;
                iDstVert := cast(s32) pTriInfos[t].vert_num[i];
                iDstOffs := pTriInfos[t].iTSpacesOffs;

                psTspace[iDstOffs + iDstVert] = psTspace[iSrcOffs + iSrcVert];
            }
            i += 1;
        }
        t += 1;
    }

    t = 0;
    while t < iNrTrianglesIn {
        if (pTriInfos[t].iFlag & QUAD_ONE_DEGEN_TRI) != 0 {
            pV := pTriInfos[t].vert_num;
            iFlag := (1 << pV[0]) | (1 << pV[1]) | (1 << pV[2]);
            iMissingIndex: s32 = 0;
            if (iFlag & 2) == 0 iMissingIndex = 1;
            else if (iFlag & 4) == 0 iMissingIndex = 2;
            else if (iFlag & 8) == 0 iMissingIndex = 3;

            iOrgF := pTriInfos[t].iOrgFaceNumber;
            vDstP := GetPosition(pContext, MakeIndex(iOrgF, iMissingIndex));
            bNotFound := TTRUE;
            i: s32 = 0;
            while bNotFound != 0 && i < 3 {
                iVert := cast(s32) pV[i];
                vSrcP := GetPosition(pContext, MakeIndex(iOrgF, iVert));
                if veq(vSrcP, vDstP) == TTRUE {
                    iOffs := pTriInfos[t].iTSpacesOffs;
                    psTspace[iOffs + iMissingIndex] = psTspace[iOffs + iVert];
                    bNotFound = TFALSE;
                } else {
                    i += 1;
                }
            }
        }
        t += 1;
    }
}

Tangent_Result :: struct {
    tangents: [..] Vector4;
    valid:    [..] bool;
}

Indexed_Triangle_Tangent_Context :: struct {
    positions: [] Vector3;
    normals: [] Vector3;
    texture_coordinates: [] Vector2;
    indices: [] u32;
    tangents: *[..] Vector4;
    valid: *[..] bool;
}

compute_tangents_from_indexed_triangles :: (
    positions: [] Vector3,
    normals: [] Vector3,
    texture_coordinates: [] Vector2,
    indices: [] u32
) -> Tangent_Result {
    result: Tangent_Result;
    array_resize(*result.tangents, positions.count);
    array_resize(*result.valid, positions.count);
    for * result.tangents it.* = .{0, 0, 0, 0};
    for * result.valid it.* = false;

    adapter: Indexed_Triangle_Tangent_Context;
    adapter.positions = positions;
    adapter.normals = normals;
    adapter.texture_coordinates = texture_coordinates;
    adapter.indices = indices;
    adapter.tangents = *result.tangents;
    adapter.valid = *result.valid;

    iface := Tangent_Space_Interface.{
        indexed_tangent_get_num_faces,
        indexed_tangent_get_num_vertices_of_face,
        indexed_tangent_get_position,
        indexed_tangent_get_normal,
        indexed_tangent_get_texcoord,
        indexed_tangent_set_tspace_basic,
        null
    };
    ctx := Tangent_Space_Context.{*iface, cast(*void) *adapter};
    generate_tangent_space_default(*ctx);

    return result;
}

indexed_tangent_get_num_faces :: (pContext: *Tangent_Space_Context) -> s32 {
    mesh := cast(*Indexed_Triangle_Tangent_Context) pContext.m_pUserData;
    return cast(s32) (mesh.indices.count / 3);
}

indexed_tangent_get_num_vertices_of_face :: (pContext: *Tangent_Space_Context, iFace: s32) -> s32 {
    return 3;
}

indexed_tangent_corner_index :: (mesh: *Indexed_Triangle_Tangent_Context, iFace: s32, iVert: s32) -> s32 {
    idx := mesh.indices[iFace * 3 + iVert];
    return cast(s32) idx;
}

indexed_tangent_get_position :: (pContext: *Tangent_Space_Context, fvPosOut: *float, iFace: s32, iVert: s32) {
    mesh := cast(*Indexed_Triangle_Tangent_Context) pContext.m_pUserData;
    idx := indexed_tangent_corner_index(mesh, iFace, iVert);
    p := mesh.positions[idx];
    fvPosOut[0] = p.x; fvPosOut[1] = p.y; fvPosOut[2] = p.z;
}

indexed_tangent_get_normal :: (pContext: *Tangent_Space_Context, fvNormOut: *float, iFace: s32, iVert: s32) {
    mesh := cast(*Indexed_Triangle_Tangent_Context) pContext.m_pUserData;
    idx := indexed_tangent_corner_index(mesh, iFace, iVert);
    n := mesh.normals[idx];
    fvNormOut[0] = n.x; fvNormOut[1] = n.y; fvNormOut[2] = n.z;
}

indexed_tangent_get_texcoord :: (pContext: *Tangent_Space_Context, fvTexcOut: *float, iFace: s32, iVert: s32) {
    mesh := cast(*Indexed_Triangle_Tangent_Context) pContext.m_pUserData;
    idx := indexed_tangent_corner_index(mesh, iFace, iVert);
    uv := mesh.texture_coordinates[idx];
    fvTexcOut[0] = uv.x; fvTexcOut[1] = uv.y;
}

indexed_tangent_set_tspace_basic :: (pContext: *Tangent_Space_Context, fvTangent: *float, fSign: float, iFace: s32, iVert: s32) {
    mesh := cast(*Indexed_Triangle_Tangent_Context) pContext.m_pUserData;
    idx := indexed_tangent_corner_index(mesh, iFace, iVert);
    mesh.tangents.*[idx] = .{fvTangent[0], fvTangent[1], fvTangent[2], fSign};
    mesh.valid.*[idx] = true;
}
